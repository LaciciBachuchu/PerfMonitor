import AppKit
import SwiftUI

/// Window for app tracking sessions: start one, watch it live, read the totals afterwards.
struct TrackingView: View {
    @Environment(Monitor.self) private var monitor
    @State private var selection: String?
    @State private var target = ""
    @State private var minutes = 30.0
    @State private var network = true
    @State private var error: String?

    static let durations: [(String, Double)] = [("5 分钟", 5), ("15 分钟", 15), ("30 分钟", 30), ("1 小时", 60), ("2 小时", 120), ("8 小时", 480), ("一直记录", 0)]

    var body: some View {
        let tracks = monitor.tracks
        let current = tracks.first { $0.id == selection } ?? tracks.first
        HStack(spacing: 10) {
            VStack(spacing: 10) {
                startForm
                list(tracks, selected: current?.id)
            }
            .frame(width: 290)
            Group {
                if let current {
                    TrackDetail(session: current)
                } else {
                    ContentUnavailableView("还没有追踪记录", systemImage: "waveform.path.ecg",
                                           description: Text("在左边输入应用名开始，或在进程列表里右键一个应用选「追踪性能」。"))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .cardBackground()
                }
            }
        }
        .padding(10)
        .frame(minWidth: 860, minHeight: 560)
        .background(WindowBackdrop().ignoresSafeArea())
        .alert(error ?? "", isPresented: Binding(get: { error != nil }, set: { if !$0 { error = nil } })) {
            Button("好") { error = nil }
        }
    }

    private var startForm: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("追踪一个应用").font(.system(size: 15, weight: .semibold)).foregroundStyle(.secondary)
            HStack(spacing: 6) {
                TextField("应用名、进程名或 PID", text: $target)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(start)
                Menu {
                    ForEach(runningApps, id: \.self) { name in Button(name) { target = name } }
                } label: { Image(systemName: "list.bullet") }
                .menuStyle(.button).fixedSize()
                .help("从正在运行的应用中选择")
            }
            HStack(spacing: 6) {
                Picker("时长", selection: $minutes) {
                    ForEach(Self.durations, id: \.1) { Text($0.0).tag($0.1) }
                }
                .labelsHidden().fixedSize()
                Toggle("网络", isOn: $network).toggleStyle(.checkbox).help("记录每个进程的网络收发（通过 nettop，每次采样约 30 毫秒 CPU）")
                Spacer()
                Button("开始", action: start)
                    .buttonStyle(.borderedProminent)
                    .disabled(target.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            Text("会合并统计应用的所有 Helper 进程。应用没打开也可以先开始，打开后自动计入。")
                .font(.caption).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
        }
        .padding(12)
        .cardBackground()
    }

    private var runningApps: [String] {
        let apps = monitor.snapshot.apps.filter(\.hasWindow)
        return Array(Set(apps.map(\.name))).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    private func start() {
        let t = target.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        switch monitor.startTracking(target: t, seconds: minutes > 0 ? minutes * 60 : nil, network: network) {
        case .success(let s): selection = s.id; target = ""
        case .failure(let e): error = e.description
        }
    }

    private func list(_ tracks: [TrackSession], selected: String?) -> some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(tracks) { s in
                    TrackRow(session: s, selected: s.id == selected)
                        .contentShape(Rectangle())
                        .onTapGesture { selection = s.id }
                        .contextMenu {
                            if s.active { Button("停止") { monitor.tracking.stop(s.id) } }
                            Button("拷贝记录 ID") { Pasteboard.copy(s.id) }
                            Button("删除", role: .destructive) { monitor.tracking.delete(s.id) }
                        }
                }
            }
            .padding(6)
        }
        .frame(maxHeight: .infinity)
        .cardBackground()
    }
}

private struct TrackRow: View {
    let session: TrackSession
    let selected: Bool

    var body: some View {
        let r = TrackReport(session, includeSamples: false)
        HStack(spacing: 8) {
            AppIcon(path: session.appPath).frame(width: 20, height: 20).scaleEffect(20 / 14)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 4) {
                    Text(session.name).font(.system(size: 13.5, weight: .medium)).lineLimit(1)
                    if session.active { Circle().fill(.red).frame(width: 6, height: 6) }
                }
                Text("\(Fmt.startTime(session.startedAt)) · \(TrackDetail.clock(r.durationSeconds))")
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 4)
            VStack(alignment: .trailing, spacing: 1) {
                Text(String(format: "%.1f%%", r.avgCpuPct)).font(.system(size: 12.5, weight: .medium)).monospacedDigit()
                Text(Fmt.energy(r.energyJ)).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(selected ? Color.accentColor.opacity(0.18) : .clear))
    }
}

private struct TrackDetail: View {
    @Environment(Monitor.self) private var monitor
    let session: TrackSession

    static func clock(_ sec: Double) -> String {
        let s = Int(sec)
        return s >= 3600 ? String(format: "%d:%02d:%02d", s / 3600, s % 3600 / 60, s % 60) : String(format: "%d:%02d", s / 60, s % 60)
    }

    var body: some View {
        let r = TrackReport(session, includeSamples: false)
        let samples = session.samples
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                header(r)
                Text(r.summary).font(.system(size: 13)).foregroundStyle(.secondary).textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)

                LazyVGrid(columns: [GridItem(.adaptive(minimum: 150), spacing: 10)], spacing: 10) {
                    tile("平均 CPU", String(format: "%.1f%%", r.avgCpuPct), String(format: "峰值 %.0f%% · 单核 = 100%%", r.peakCpuPct))
                    tile("占整机 CPU", String(format: "%.1f%%", r.shareOfMachineCpuPct), String(format: "占已用 CPU 的 %.0f%%", r.shareOfUsedCpuPct))
                    tile("CPU 时间", Fmt.duration(r.cpuSeconds), "所有进程合计")
                    tile("内存", ByteFormat.short(r.avgMemoryBytes), "峰值 " + ByteFormat.short(r.peakMemoryBytes))
                    tile("CPU 能耗", Fmt.energy(r.energyJ), (r.powerEstimated ? "≈" : "") + String(format: "平均 %.2f W", r.avgPowerW))
                    tile("占整机能耗", String(format: "%.1f%%", r.shareOfSystemEnergyPct), String(format: "整机平均 %.1f W", r.systemAvgPowerW))
                    tile("GPU", String(format: "%.1f%%", r.avgGpuPct), String(format: "峰值 %.0f%% · GPU 时间 ", r.peakGpuPct ?? 0) + Fmt.duration(r.gpuSeconds))
                    tile("磁盘", ByteFormat.short(r.diskReadBytes + r.diskWrittenBytes), "读 \(ByteFormat.short(r.diskReadBytes)) · 写 \(ByteFormat.short(r.diskWrittenBytes))")
                    if let i = r.networkInBytes, let o = r.networkOutBytes {
                        tile("网络", ByteFormat.short(i + o), "↓ \(ByteFormat.short(i)) · ↑ \(ByteFormat.short(o))")
                        tile("网络速率", ByteFormat.rate(r.avgNetworkBps ?? 0), "峰值 " + ByteFormat.rate(r.peakNetworkBps ?? 0))
                    } else if let n = r.networkBytes {
                        tile("网络", ByteFormat.short(n), "收发合计")
                    } else {
                        tile("网络", "未记录", "开始时没有勾选「网络」")
                    }
                    tile("空闲唤醒", String(format: "%.0f 次/秒", r.idleWakeupsPerSec), "越低越省电")
                }

                chart("CPU", unit: "%", color: .blue, samples.map(\.cpuPct))
                chart("内存", unit: "GB", color: .green, samples.map { $0.memoryBytes / 1_073_741_824 })
                chart("CPU 功耗", unit: "W", color: .orange, samples.map(\.powerW))
                chart("GPU", unit: "%", color: .purple, samples.map(\.gpuPct))
                if session.includeNetwork { chart("网络", unit: "KB/s", color: .teal, samples.map { $0.netBps / 1024 }) }
                chart("磁盘", unit: "MB/s", color: .brown, samples.map { $0.diskBps / 1_048_576 })

                if !r.processes.isEmpty { parts(r) }
            }
            .padding(14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .cardBackground()
    }

    private func header(_ r: TrackReport) -> some View {
        HStack(spacing: 10) {
            AppIcon(path: session.appPath).frame(width: 36, height: 36).scaleEffect(36 / 14)
            VStack(alignment: .leading, spacing: 2) {
                Text(session.name).font(.title2.bold())
                Text(statusLine(r)).font(.callout).foregroundStyle(session.active ? Color.red : .secondary).monospacedDigit()
            }
            Spacer()
            if session.active {
                Button("停止") { monitor.tracking.stop(session.id) }.buttonStyle(.borderedProminent)
            }
            Menu {
                Button("拷贝汇总") { Pasteboard.copy(r.summary) }
                Button("拷贝 JSON") { Pasteboard.copy(JSON.string(TrackReport(session, includeSamples: true))) }
                Button("拷贝记录 ID") { Pasteboard.copy(session.id) }
                Button("在访达中显示文件") { NSWorkspace.shared.activateFileViewerSelecting([Tracker.file(session.id)]) }
                Divider()
                Button("删除记录", role: .destructive) { monitor.tracking.delete(session.id) }
            } label: { Image(systemName: "ellipsis.circle") }
            .menuStyle(.button).fixedSize()
        }
    }

    private func statusLine(_ r: TrackReport) -> String {
        var s = "\(Fmt.startTime(session.startedAt)) 开始 · "
        if session.active {
            s += "● 正在记录 \(Self.clock(r.durationSeconds))"
            if let plan = session.plannedSeconds { s += " / \(Self.clock(plan))" }
        } else {
            s += "共 \(Self.clock(r.durationSeconds))" + (session.interrupted ? "（PerfMonitor 退出，记录中断）" : "")
        }
        if r.runningSeconds < r.durationSeconds * 0.98 { s += " · 应用运行了 \(Self.clock(r.runningSeconds))" }
        return s
    }

    private func tile(_ label: String, _ value: String, _ sub: String) -> some View {
        Metric(label: label, value: value, sub: sub)
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 10, style: .continuous).fill(.quaternary.opacity(0.35)))
    }

    private func chart(_ title: String, unit: String, color: Color, _ values: [Double]) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(title).font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
                Spacer()
                if let last = values.last { let f = (values.max() ?? 0) < 1 ? "%.2f" : "%.1f"; Text(String(format: "当前 \(f) %@ · 峰值 \(f) %@", last, unit, values.max() ?? 0, unit)).font(.caption).foregroundStyle(.secondary).monospacedDigit() }
            }
            Sparkline(series: [.init(name: title, color: color, values: values, fill: true)],
                      range: 0...max((values.max() ?? 1) * 1.1, unit == "%" ? 10 : 0.1), unit: unit, height: 70, flexible: false)
        }
    }

    private func parts(_ r: TrackReport) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("各进程").font(.system(size: 13, weight: .medium)).foregroundStyle(.secondary)
            Grid(alignment: .trailing, horizontalSpacing: 16, verticalSpacing: 4) {
                GridRow {
                    Text("进程").gridColumnAlignment(.leading)
                    Text("CPU 时间"); Text("占比"); Text("能耗"); Text("内存峰值"); Text("GPU 时间"); Text("磁盘")
                    if r.networkInBytes != nil { Text("网络 ↓"); Text("网络 ↑") }
                }
                .font(.caption).foregroundStyle(.secondary)
                ForEach(r.processes, id: \.name) { p in
                    GridRow {
                        Text(p.name).lineLimit(1).truncationMode(.middle).gridColumnAlignment(.leading)
                        Text(Fmt.duration(p.cpuSeconds))
                        Text(r.cpuSeconds > 0 ? String(format: "%.0f%%", p.cpuSeconds / r.cpuSeconds * 100) : "—")
                        Text(Fmt.energy(p.energyJ))
                        Text(ByteFormat.short(p.peakMemoryBytes))
                        Text(Fmt.duration(p.gpuSeconds))
                        Text(ByteFormat.short(p.diskBytes))
                        if let i = p.networkInBytes, let o = p.networkOutBytes { Text(ByteFormat.short(i)); Text(ByteFormat.short(o)) }
                    }
                    .font(.system(size: 12.5)).monospacedDigit()
                }
            }
        }
    }
}
