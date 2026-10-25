import SwiftUI

// MARK: - Charging & ports

struct ChargingCard: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let p = monitor.dashboard.power
        Card("充电与供电", icon: p.batteryW > 0.05 ? "battery.100percent.bolt" : "powerplug",
             hero: p.hasBattery ? Fmt.pct(p.percent) : nil, heroValue: p.percent) {
            EmptyView()
        } content: {
            MetricRow {
                Metric(label: chargeLabel(p),
                       value: Fmt.watts(abs(p.batteryW) > 0.05 ? abs(p.batteryW) : 0),
                       color: p.batteryW > 0.05 ? .green : (p.batteryW < -0.05 ? .orange : .primary),
                       sub: p.minutesToFull.map { "约 \($0) 分钟充满" } ?? p.minutesToEmpty.map { "约 \($0 / 60) 时 \($0 % 60) 分可用" })
                Metric(label: "USB-C 输入", value: p.onAC ? Fmt.watts(p.systemInW) : "未接电源",
                       sub: p.adapter.map { String(format: "%.0fV × %.2fA", $0.volts, $0.amps) })
                Metric(label: "接口对外供电", value: Fmt.watts(p.portsOutW), color: p.portsOutW > 0 ? .blue : .primary,
                       sub: p.portsOut.isEmpty ? "无设备取电" : p.portsOut.map { String(format: "口%d %.1fV×%.2fA", $0.index, $0.volts, $0.amps) }.joined(separator: " "))
            }
            let h = monitor.history
            Sparkline(series: [
                .init(name: "USB-C 输入", color: .green, values: h.map(\.inputW), fill: true),
                .init(name: "电池", color: .orange, values: h.map(\.batteryW)),
                .init(name: "接口对外", color: .blue, values: h.map(\.portsOutW)),
            ], unit: "W")
            InfoLine(items: [
                p.adapter.map { String(format: "适配器 %.0f W（%@）", $0.ratedW, $0.description) } ?? "未接适配器",
                p.adapter?.maxOfferedW.map { String(format: "PD 档位表最高 %.0f W", $0) } ?? "",
                p.systemLoadW.map { "系统负载 " + Fmt.watts($0) } ?? "",
            ].filter { !$0.isEmpty })
            InfoLine(items: [
                p.health.map { "电池健康 " + Fmt.pct($0) } ?? "",
                p.cycles.map { "循环 \($0) 次" } ?? "",
                p.designCapacityMAh.map { "设计容量 \($0) mAh" } ?? "",
                (p.thermallyLimitedChargeSeconds ?? 0) > 0 ? "曾因温度限速充电 \(p.thermallyLimitedChargeSeconds! / 60) 分钟" : "",
            ].filter { !$0.isEmpty })
        }
    }

    private func chargeLabel(_ p: PowerSampler.Result) -> String {
        if p.batteryW > 0.05 { return "正在充电" }
        if p.batteryW < -0.05 { return "电池放电" }
        if p.fullyCharged { return "已充满" }
        return p.onAC ? "未在充电" : "电池"
    }
}

// MARK: - Hardware

struct HardwareCard: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        Card("硬件信息", icon: "laptopcomputer") {
            if let note = monitor.hardware?.officialSpec?.note {
                Text(note).font(.system(size: 9)).foregroundStyle(.tertiary)
            }
            Button { monitor.refreshHardware() } label: { Image(systemName: "arrow.clockwise").font(.caption) }
                .buttonStyle(.borderless).help("重新读取（显示器、存储空间）")
        } content: {
            if let h = monitor.hardware {
                // Adaptive columns: as many as fit, so the card stays short at any width.
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 270), spacing: 18, alignment: .topLeading)],
                          alignment: .leading, spacing: 5) {
                    ForEach(Array(rows(h).enumerated()), id: \.offset) { _, row in
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            Text(row.0).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                            Text(row.1).textSelection(.enabled).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        }
                        .font(.system(size: 12))
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
    }

    private func rows(_ h: HardwareInfo) -> [(String, String)] {
        var r: [(String, String)] = []
        r.append(("型号", "\(h.modelName.isEmpty ? "Mac" : h.modelName)（\(h.modelID)）"))
        r.append(("芯片", h.chip))
        var cpu = "\(h.performanceCores)P + \(h.efficiencyCores)E"
        if let p = h.pCoreMaxMhz, let e = h.eCoreMaxMhz { cpu += String(format: "，最高 %.2f / %.2f GHz", p / 1000, e / 1000) }
        r.append(("CPU", cpu))
        var gpu = h.gpuCores.map { "\($0) 核" } ?? "—"
        if let g = h.gpuMaxMhz { gpu += String(format: "，最高 %.0f MHz", g) }
        r.append(("GPU", gpu))
        r.append(("内存", String(format: "%.0f GB", h.memoryGB) + [h.memoryType, h.memoryMaker].compactMap { $0 }.map { " " + $0 }.joined()))
        if let b = h.storageBytes {
            var t = (h.storageModel.map { $0 + " " } ?? "") + ByteFormat.short(b)
            if let f = h.storageFreeBytes { t += "，可用 \(ByteFormat.short(f))" }
            r.append(("存储", t))
        }
        for d in h.displays {
            var t = "\(d.current)；最高 \(d.maxResolution)"
            if let hz = d.maxRefreshHz { t += String(format: " / %.0f Hz", hz) }
            r.append((d.builtIn ? "内建屏" : "外接屏", (d.builtIn ? "" : d.name + " ") + t))
        }
        if let spec = h.officialSpec {
            if let s = spec.builtInDisplay { r.append(("屏幕规格", s)) }
            if let s = spec.externalDisplays { r.append(("外接规格", s)) }
            if let s = spec.charging { r.append(("充电规格", s)) }
        }
        if let a = monitor.dashboard.power.adapter {
            var t = String(format: "当前 %.0f W（%.0fV × %.2fA）", a.ratedW, a.volts, a.amps)
            if let o = a.maxOfferedW { t += String(format: "，档位表最高 %.0f W", o) }
            r.append(("充电功率", t))
        }
        r.append(("散热", h.fans == 0 ? "被动散热（无风扇）" : "\(h.fans) 个风扇"))
        r.append(("macOS", h.macosVersion))
        r.append(("功耗来源", powerSourceLabel(monitor.dashboard.io.cpuPowerSource)))
        return r
    }

    private func powerSourceLabel(_ s: String) -> String {
        switch s {
        case "clpc": return "AppleCLPC 计数器（macOS 27）"
        case "energy-model": return "IOReport Energy Model"
        default: return "按进程能耗估算"
        }
    }
}
