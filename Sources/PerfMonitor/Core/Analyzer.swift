import Foundation

struct Finding: Identifiable, Hashable {
    enum Severity: Int, Comparable {
        case info, warning, critical
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
    }
    enum Kind: String { case thermal, cpu, singleThread, gpu, memory, disk, power, idle }

    var id: String { kind.rawValue }
    let kind: Kind
    let severity: Severity
    let title: String
    let detail: String
    let advice: String
}

/// Turns the last few snapshots into a plain-language bottleneck diagnosis.
/// Averages over the window so a single spike doesn't flip the verdict.
enum Analyzer {
    static func analyze(recent: [Snapshot], lowPower: Bool) -> [Finding] {
        guard let last = recent.last, !recent.isEmpty else { return [] }
        func avg(_ f: (Snapshot) -> Double) -> Double { recent.map(f).reduce(0, +) / Double(recent.count) }

        let cpu = avg { $0.system.cpuTotal }
        let pActive = avg { $0.io.pCluster.active }
        let eActive = avg { $0.io.eCluster.active }
        let pFreq = avg { $0.io.pCluster.freqMHz }
        let pMax = last.io.pCluster.maxMHz
        let gpu = avg { $0.system.gpuUtil ?? $0.io.gpu.active }
        let gpuCapped = avg { max($0.io.gpuThermalLimited, $0.io.gpuPerfLost) }
        let swapOut = avg { $0.system.memory.swapOutsPerSec }
        let swapIn = avg { $0.system.memory.swapInsPerSec }
        let disk = avg { $0.system.diskReadBps + $0.system.diskWriteBps }
        let thermal = last.system.thermal
        let mem = last.system.memory
        let top = topByCPU(last.processes)

        var out: [Finding] = []

        // Thermal wall
        let freqRatio = pMax > 0 && pFreq > 0 ? pFreq / pMax : 1
        let cpuThrottled = pActive > 0.6 && freqRatio < 0.75
        if thermal >= .moderate || gpuCapped > 0.05 || (cpuThrottled && thermal > .nominal) {
            var parts = ["系统热压力：\(thermal.label)"]
            if let t = last.hottest { parts.append(String(format: "最高温度 %.0f°C", t)) }
            if pMax > 0, pActive > 0.3 { parts.append(String(format: "P 核均频 %.0f / %.0f MHz（%.0f%%）", pFreq, pMax, freqRatio * 100)) }
            if gpuCapped > 0.05 { parts.append(String(format: "GPU %.0f%% 时间被热管理限频", gpuCapped * 100)) }
            out.append(Finding(
                kind: .thermal,
                severity: thermal >= .heavy ? .critical : .warning,
                title: cpuThrottled || gpuCapped > 0.05 || thermal >= .heavy ? "撞到温度墙，正在降频" : "热压力升高，接近温度墙",
                detail: parts.joined(separator: " · "),
                advice: last.sensors.fans.isEmpty
                    ? "这台 Mac 是被动散热：垫高机身底部、别放在软面上、关掉不用的高负载进程；也可以切到低功耗模式换取更稳的持续性能。"
                    : "检查出风口是否被遮挡；高负载持续任务可考虑外接散热或切到高性能模式。"
            ))
        }

        // CPU
        if let t = top, t.cpu >= 85, t.cpu <= 120, cpu < 0.6 {
            out.append(Finding(
                kind: .singleThread, severity: .warning,
                title: "单线程瓶颈：\(t.name)",
                detail: String(format: "%@ 吃满了约一个核（%.0f%%），但整机 CPU 只用了 %.0f%%。", t.name, t.cpu, cpu * 100),
                advice: "核数再多也帮不上忙，瓶颈在这个程序本身的单线程性能。只能等它完成，或看看程序里有没有多线程/硬件加速选项。"
            ))
        } else if cpu > 0.85 || (pActive > 0.9 && eActive > 0.8) {
            let names = topNames(last.apps, by: \.cpu, count: 3, unit: { String(format: "%.0f%%", $0) })
            out.append(Finding(
                kind: .cpu, severity: cpu > 0.95 ? .critical : .warning,
                title: "CPU 跑满",
                detail: String(format: "整机 CPU %.0f%%（P 核 %.0f%%，E 核 %.0f%%）。主要占用：%@", cpu * 100, pActive * 100, eActive * 100, names),
                advice: "不急的后台任务可以在进程列表右键「限制到能效核」，把 P 核让给前台应用。"
            ))
        }

        // GPU
        if gpu > 0.85 {
            out.append(Finding(
                kind: .gpu, severity: .warning,
                title: "GPU 跑满",
                detail: String(format: "GPU 利用率 %.0f%%，频率 %.0f MHz，功耗 %.1f W。", gpu * 100, last.io.gpu.freqMHz, last.io.gpuW),
                advice: "图形/视频/本地模型类任务受限于 GPU。降低分辨率或帧率、关掉多余的动画和视频窗口会有效。"
            ))
        }

        // Memory
        let swapping = swapOut > 50 || swapIn > 200
        if mem.pressureLevel >= 2 || swapping {
            let names = topNames(last.apps, by: \.memory, count: 3, unit: { ByteFormat.short($0) })
            out.append(Finding(
                kind: .memory,
                severity: mem.pressureLevel >= 4 || swapOut > 500 ? .critical : .warning,
                title: swapping ? "内存不足，正在频繁换页" : "内存压力偏高",
                detail: String(format: "已用 %@ / %@，交换区 %@，换入 %.0f / 换出 %.0f 页/秒。占用最多：%@",
                               ByteFormat.short(mem.used), ByteFormat.short(mem.total), ByteFormat.short(mem.swapUsed), swapIn, swapOut, names),
                advice: "换页会让一切都变慢、还会磨损 SSD。关掉不用的浏览器标签页和 Electron 应用（它们每个都是一组进程）收益最大。"
            ))
        }

        // Disk
        if disk > 150_000_000 {
            let names = topNames(last.apps, by: \.diskBps, count: 2, unit: { ByteFormat.rate($0) })
            out.append(Finding(
                kind: .disk, severity: .info,
                title: "磁盘 I/O 繁忙",
                detail: "读写合计 \(ByteFormat.rate(disk))。主要来自：\(names)",
                advice: swapping ? "很可能是内存换页导致的，先解决内存问题。" : "大文件拷贝、索引（Spotlight）或备份时属正常。"
            ))
        }

        if lowPower, cpu > 0.5 || gpu > 0.5 {
            out.append(Finding(
                kind: .power, severity: .info,
                title: "低功耗模式正在限制性能",
                detail: "当前负载较高，而低功耗模式会压低 P 核和 GPU 频率。",
                advice: "需要性能时切回「自动」。"
            ))
        }

        if out.isEmpty {
            out.append(Finding(
                kind: .idle, severity: .info,
                title: "没有明显瓶颈",
                detail: String(format: "CPU %.0f%%，GPU %.0f%%，内存压力正常，温度正常。", cpu * 100, gpu * 100),
                advice: "如果仍然感觉卡，可能是某个应用自身的问题，或者在等网络。"
            ))
        }
        return out.sorted { $0.severity > $1.severity }
    }

    private static func topByCPU(_ list: [ProcessStat]) -> ProcessStat? {
        list.max { $0.cpu < $1.cpu }
    }

    private static func topNames(_ list: [ProcessStat], by key: KeyPath<ProcessStat, Double>, count: Int, unit: (Double) -> String) -> String {
        list
            .sorted { $0[keyPath: key] > $1[keyPath: key] }
            .prefix(count)
            .map { "\($0.name) \(unit($0[keyPath: key]))" }
            .joined(separator: "、")
    }
}

enum ByteFormat {
    static func short(_ bytes: Double) -> String {
        let units = ["B", "KB", "MB", "GB", "TB"]
        var v = bytes, i = 0
        while v >= 1024, i < units.count - 1 { v /= 1024; i += 1 }
        return i >= 3 ? String(format: "%.1f %@", v, units[i]) : String(format: "%.0f %@", v, units[i])
    }

    static func rate(_ bps: Double) -> String { short(bps) + "/s" }
}
