import AppKit
import SwiftUI

struct DashboardView: View {
    @Environment(Monitor.self) private var monitor
    @AppStorage("processPanelWidth") private var panelWidth = 560.0
    @State private var dragStart: Double?

    var body: some View {
        // Plain HStack instead of HSplitView: the split view's cursor rects get rebuilt on every
        // refresh, which re-renders the (accessibility-sized) pointer and costs ~40% CPU.
        // Explicit frames from GeometryReader: when a stack has to ask its scroll views how big
        // they want to be, SwiftUI measures every process row on each refresh.
        GeometryReader { g in
            if monitor.dashboardActive {
                let pw = min(max(panelWidth, 420), max(g.size.width - 600, 420))
                HStack(spacing: 0) {
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            HeaderBar()
                            FindingsView(findings: monitor.findings)
                            Grid(horizontalSpacing: 8, verticalSpacing: 8) {
                                GridRow { ThermalCard(); PowerCard() }
                                GridRow { CPUCard(); GPUCard() }
                                GridRow { MemoryCard(); ChargingCard() }
                                GridRow { HardwareCard().gridCellColumns(2) }
                            }
                        }
                        .padding(10)
                    }
                    .frame(width: max(g.size.width - pw - 5, 0), height: g.size.height)

                    // Drag to resize the process panel.
                    Rectangle().fill(.separator).frame(width: 1)
                        .padding(.horizontal, 2)
                        .contentShape(Rectangle())
                        .frame(width: 5, height: g.size.height)
                        .onHover { inside in if inside { NSCursor.resizeLeftRight.push() } else { NSCursor.pop() } }
                        .gesture(DragGesture(minimumDistance: 1)
                            .onChanged { v in
                                let start = dragStart ?? pw
                                dragStart = start
                                panelWidth = min(max(start - v.translation.width, 420), g.size.width - 600)
                            }
                            .onEnded { _ in dragStart = nil })

                    ProcessPanel()
                        .frame(width: pw, height: g.size.height)
                }
            } else {
                // Window closed/minimized/covered: drop the whole view tree to free its memory.
                Color.clear
            }
        }
        .frame(minWidth: 1140, minHeight: 700)
        .background(WindowVisibilityReader { monitor.dashboardVisible = $0 })
    }
}

/// Reports whether the hosting window is actually on screen (not closed, minimized or fully covered).
struct WindowVisibilityReader: NSViewRepresentable {
    let onChange: (Bool) -> Void

    func makeNSView(context: Context) -> NSView {
        let v = ObservingView()
        v.onChange = onChange
        return v
    }

    func updateNSView(_ nsView: NSView, context: Context) {}

    final class ObservingView: NSView {
        var onChange: ((Bool) -> Void)?
        private var tokens: [NSObjectProtocol] = []

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            tokens.forEach(NotificationCenter.default.removeObserver)
            tokens = []
            guard let window else { onChange?(false); return }
            let report: (Notification) -> Void = { [weak self] n in
                guard let self, let w = self.window else { return }
                self.onChange?(n.name != NSWindow.willCloseNotification && Self.isVisible(w))
            }
            for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.willCloseNotification,
                         NSWindow.didMiniaturizeNotification, NSWindow.didDeminiaturizeNotification] {
                tokens.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main, using: report))
            }
            // Hiding the whole app (⌘H) doesn't change the window's occlusion state.
            for name in [NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
                tokens.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main, using: report))
            }
            onChange?(Self.isVisible(window))
        }

        static func isVisible(_ w: NSWindow) -> Bool {
            !NSApp.isHidden && w.isVisible && !w.isMiniaturized && w.occlusionState.contains(.visible)
        }
    }
}

// MARK: - Header

struct HeaderBar: View {
    @Environment(Monitor.self) private var monitor
    @State private var status: String?
    @State private var busy = false
    @State private var showInfo = false
    @AppStorage("floatingPanel") private var floating = false

    var body: some View {
        let ps = monitor.powerState
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 0) {
                Text("性能监控").font(.headline)
                Text(Host.current().localizedName ?? "Mac").font(.caption2).foregroundStyle(.secondary)
            }
            .fixedSize()
            Spacer(minLength: 6)

            ForEach(PowerSource.allCases) { source in
                HStack(spacing: 4) {
                    Image(systemName: source == .battery ? "battery.75percent" : "powerplug").font(.caption)
                        .foregroundStyle(.secondary).help(source == .battery ? "使用电池时" : "接通电源时")
                    Picker("", selection: Binding(get: { ps.mode(for: source) }, set: { apply($0, [source]) })) {
                        ForEach(PowerMode.allCases.filter { $0 != .high || ps.supportsHigh }) { Text($0.label).tag($0) }
                    }
                    .pickerStyle(.segmented).labelsHidden()
                    .frame(width: ps.supportsHigh ? 170 : 110)
                }
            }
            .disabled(busy)

            Button {
                busy = true
                monitor.setPasswordless(!ps.passwordless) { err in busy = false; status = err }
            } label: {
                Image(systemName: ps.passwordless ? "lock.open.fill" : "lock.fill")
                    .foregroundStyle(ps.passwordless ? .green : .secondary)
            }
            .buttonStyle(.borderless)
            .help(ps.passwordless
                  ? "已开启免密码切换（/etc/sudoers.d/perfmonitor，只允许 pmset 低功耗/性能模式命令）。点击可移除。"
                  : "切换档位目前每次都要输入密码。点击做一次授权：以后切换不再需要密码（只放行 pmset 低功耗/性能模式命令）。")
            .disabled(busy)

            Button { showInfo.toggle() } label: { Image(systemName: "info.circle") }
                .buttonStyle(.borderless)
                .popover(isPresented: $showInfo, arrowEdge: .bottom) { PowerInfo(supportsHigh: ps.supportsHigh) }

            Toggle(isOn: $floating) { Image(systemName: "pip") }.toggleStyle(.button).help("悬浮窗")

            Picker("", selection: Binding(get: { monitor.interval }, set: { monitor.setInterval($0) })) {
                Text("1 秒").tag(1.0)
                Text("2 秒").tag(2.0)
                Text("3 秒").tag(3.0)
            }
            .labelsHidden().frame(width: 64).help("采样间隔")
        }
        .overlay(alignment: .bottomTrailing) {
            if busy || status != nil {
                Text(busy ? "请在系统授权窗口中输入 Mac 登录密码…" : status!)
                    .font(.caption2).foregroundStyle(busy ? .orange : .red)
                    .offset(y: 13)
            }
        }
        .padding(.bottom, busy || status != nil ? 10 : 0)
    }

    private func apply(_ mode: PowerMode, _ sources: [PowerSource]) {
        busy = !monitor.powerState.passwordless
        status = nil
        monitor.applyPowerMode(mode, sources: sources) { err in busy = false; status = err }
    }
}

private struct PowerInfo: View {
    let supportsHigh: Bool
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("性能档位说明").font(.headline)
            if supportsHigh {
                Text("这台 Mac 支持「高性能」模式：允许更高的持续功耗和更积极的风扇，适合长时间满载。")
            } else {
                Text("这台 Mac 没有「高性能」模式。macOS 只在部分 MacBook Pro（Max 芯片等）上提供 High Power Mode；本机 pmset 的能力列表里只有 lowpowermode。")
                Text("所以「自动」已经是最激进的档位：两种供电都设成「自动」即可。")
                Text("这台机器是被动散热，真正限制持续性能的是温度墙。想跑得更久：垫高机身底部、别放在软面上，并把不急的后台任务在进程列表里右键「限制到能效核」。")
            }
            Text("每种供电状态（电池 / 电源）可以分别设置。点锁形按钮做一次授权，以后切换不再需要输入密码。").foregroundStyle(.secondary)
        }
        .font(.callout)
        .frame(width: 340)
        .padding(14)
    }
}

// MARK: - Findings

struct FindingsView: View {
    let findings: [Finding]

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            ForEach(findings) { f in
                HStack(alignment: .top, spacing: 8) {
                    RoundedRectangle(cornerRadius: 1.5).fill(Palette.severity(f.severity)).frame(width: 3)
                    VStack(alignment: .leading, spacing: 1) {
                        (Text(f.title).bold() + Text("  " + f.detail).foregroundColor(.secondary))
                            .font(.caption).fixedSize(horizontal: false, vertical: true)
                        Text(f.advice).font(.caption2).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 5).padding(.horizontal, 8)
                .background(Palette.severity(f.severity).opacity(0.08), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            }
        }
    }
}

// MARK: - Thermal

struct ThermalCard: View {
    @Environment(Monitor.self) private var monitor
    @State private var showSensors = false

    var body: some View {
        let s = monitor.dashboard
        let h = monitor.history
        Card("温度", icon: "thermometer.medium") {
            Text("热压力 \(s.system.thermal.label)")
                .font(.caption2.bold())
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(Palette.thermal(s.system.thermal).opacity(0.18), in: Capsule())
                .foregroundStyle(Palette.thermal(s.system.thermal))
            Button("全部传感器") { showSensors.toggle() }
                .buttonStyle(.borderless).font(.caption2)
                .popover(isPresented: $showSensors, arrowEdge: .trailing) { SensorsList() }
        } content: {
            HStack(spacing: 4) {
                Metric(label: "SoC", value: Fmt.temp(s.socTemp), color: Palette.temp(s.socTemp), sub: s.sensors.soc.map { "最高 " + Fmt.temp($0.max) })
                Metric(label: "P 核", value: Fmt.temp(s.sensors.pCores?.avg), color: Palette.temp(s.sensors.pCores?.avg), sub: s.sensors.pCores.map { "热点 " + Fmt.temp($0.max) })
                Metric(label: "E 核", value: Fmt.temp(s.sensors.eCores?.avg), color: Palette.temp(s.sensors.eCores?.avg), sub: s.sensors.eCores.map { "最高 " + Fmt.temp($0.max) })
                Metric(label: "GPU", value: Fmt.temp(s.sensors.gpu?.avg), color: Palette.temp(s.sensors.gpu?.avg), sub: s.sensors.gpu.map { "最高 " + Fmt.temp($0.max) })
                Metric(label: "SSD", value: Fmt.temp(s.sensors.ssd), color: Palette.temp(s.sensors.ssd))
                Metric(label: "电池", value: Fmt.temp(s.sensors.battery), color: Palette.temp(s.sensors.battery))
            }
            Sparkline(series: [
                .init(name: "P 核", color: .red, values: h.map(\.pTemp)),
                .init(name: "E 核", color: .orange, values: h.map(\.eTemp)),
                .init(name: "GPU", color: .purple, values: h.map(\.gpuTemp)),
                .init(name: "SoC", color: .blue, values: h.map(\.socTemp)),
            ], unit: "°")
            InfoLine(items: [s.sensors.fans.isEmpty ? "被动散热（无风扇）" : "风扇 " + s.sensors.fans.map { String(format: "%.0f rpm", $0) }.joined(separator: " / "),
                             "内存与 SoC 同封装，无独立温度传感器"])
        }
    }
}

struct SensorsList: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let groups = Dictionary(grouping: monitor.allSensors, by: \.group).sorted { $0.key < $1.key }
        ScrollView {
            if groups.isEmpty {
                ProgressView().controlSize(.small).padding(30)
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 200), spacing: 12, alignment: .topLeading)], alignment: .leading, spacing: 10) {
                    ForEach(groups, id: \.key) { group, items in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(group).font(.caption.bold())
                            ForEach(items) { r in
                                HStack {
                                    Text(r.label + (r.inferred ? "*" : "")).lineLimit(1)
                                    Spacer()
                                    Text(String(format: r.unit == "°C" ? "%.1f %@" : "%.2f %@", r.value, r.unit)).monospacedDigit()
                                        .foregroundStyle(r.unit == "°C" ? Palette.temp(r.value) : .primary)
                                }
                                .font(.caption2)
                                .help("\(r.source) \(r.key)")
                            }
                        }
                    }
                }
                .padding(12)
                Text("* 为根据数值比对推测的标注；悬停可查看原始 SMC/HID 键名。").font(.caption2).foregroundStyle(.tertiary).padding(.bottom, 8)
            }
        }
        .frame(width: 680, height: 520)
        .onAppear { monitor.wantsAllSensors = true }
        .onDisappear { monitor.wantsAllSensors = false }
    }
}

// MARK: - Power

struct PowerCard: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let s = monitor.dashboard
        let h = monitor.history
        let other = max(0, s.totalW - s.io.cpuW - s.io.gpuW - s.io.aneW)
        Card("功耗", icon: "bolt.fill") {
            Text("整机 " + Fmt.watts(s.totalW)).font(.subheadline.bold().monospacedDigit())
        } content: {
            HStack(spacing: 4) {
                Metric(label: "CPU", value: Fmt.watts(s.io.cpuW), color: .red,
                       sub: s.io.cpuPowerSource == "process-estimate" ? "进程能耗估算" : nil)
                Metric(label: "GPU", value: Fmt.watts(s.io.gpuW), color: .purple)
                Metric(label: "神经引擎", value: Fmt.watts(s.io.aneW), color: .teal)
                if s.io.dramAvailable {
                    Metric(label: "内存", value: Fmt.watts(s.io.dramW), color: .green)
                }
                Metric(label: "其他", value: Fmt.watts(other), color: .gray, sub: "屏幕/内存/外设")
                Metric(label: "USB-C 输入", value: s.power.onAC ? Fmt.watts(s.power.systemInW) : "—")
            }
            Sparkline(series: [
                .init(name: "CPU", color: .red, values: h.map(\.cpuW)),
                .init(name: "GPU", color: .purple, values: h.map(\.gpuW)),
                .init(name: "其他", color: .gray, values: h.map(\.otherW)),
            ], unit: "W", stacked: true)
            InfoLine(items: ["SMC 整机 " + Fmt.watts(s.sensors.systemW),
                             "系统负载 " + Fmt.watts(s.power.systemLoadW),
                             "接口对外 " + Fmt.watts(s.power.portsOutW)])
        }
    }
}

// MARK: - CPU

struct CPUCard: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let s = monitor.dashboard
        let h = monitor.history
        let p = s.io.pCluster, e = s.io.eCluster
        Card("CPU", icon: "cpu") {
            Text(Fmt.pct(s.system.cpuTotal)).font(.subheadline.bold().monospacedDigit()).foregroundStyle(Palette.load(s.system.cpuTotal))
        } content: {
            HStack(spacing: 4) {
                Metric(label: "P 核", value: Fmt.mhz(p.freqMHz), sub: p.maxMHz > 0 ? "上限 \(Fmt.mhz(p.maxMHz)) · \(Fmt.pct(p.active))" : nil)
                Metric(label: "E 核", value: Fmt.mhz(e.freqMHz), sub: e.maxMHz > 0 ? "上限 \(Fmt.mhz(e.maxMHz)) · \(Fmt.pct(e.active))" : nil)
                Metric(label: "功耗", value: Fmt.watts(s.io.cpuW), color: .red)
            }
            LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 3) {
                ForEach(s.io.cores, id: \.name) { c in
                    LabeledBar(label: c.name, value: c.active, text: "\(Fmt.pct(c.active)) \(Fmt.mhz(c.freqMHz))",
                               tint: c.name.hasPrefix("P") ? .red : .orange)
                }
            }
            Sparkline(series: [
                .init(name: "P 核 MHz", color: .red, values: h.map(\.pFreq)),
                .init(name: "E 核 MHz", color: .orange, values: h.map(\.eFreq)),
            ], range: 0...max(p.maxMHz, 1), height: 36)
        }
    }
}

// MARK: - GPU

struct GPUCard: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let s = monitor.dashboard
        let h = monitor.history
        let capped = max(s.io.gpuThermalLimited, s.io.gpuPerfLost)
        Card("GPU", icon: "square.stack.3d.up.fill") {
            Text(Fmt.pct(s.gpuUtil)).font(.subheadline.bold().monospacedDigit()).foregroundStyle(Palette.load(s.gpuUtil))
        } content: {
            HStack(spacing: 4) {
                Metric(label: "频率", value: Fmt.mhz(s.io.gpu.freqMHz), sub: s.io.gpu.maxMHz > 0 ? "上限 \(Fmt.mhz(s.io.gpu.maxMHz))" : nil)
                Metric(label: "功耗", value: Fmt.watts(s.io.gpuW), color: .purple)
                Metric(label: "热限频", value: Fmt.pct(capped), color: capped > 0.05 ? .orange : .green, sub: "被温度压频的时间")
            }
            Sparkline(series: [
                .init(name: "CPU %", color: .red, values: h.map { $0.cpu * 100 }),
                .init(name: "GPU %", color: .purple, values: h.map { $0.gpu * 100 }, fill: true),
            ], range: 0...100, unit: "%", height: 58)
        }
    }
}

// MARK: - Memory

struct MemoryCard: View {
    @Environment(Monitor.self) private var monitor

    var body: some View {
        let sys = monitor.dashboard.system
        let m = sys.memory
        let (label, color): (String, Color) = switch m.pressureLevel {
        case 4...: ("严重", .red)
        case 2...: ("警告", .orange)
        default: ("正常", .green)
        }
        Card("内存与磁盘", icon: "memorychip") {
            Text("压力 \(label)").font(.caption2.bold())
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(color.opacity(0.18), in: Capsule()).foregroundStyle(color)
        } content: {
            HStack(spacing: 4) {
                Metric(label: "已用", value: ByteFormat.short(m.used), sub: "共 \(ByteFormat.short(m.total))")
                Metric(label: "交换区", value: ByteFormat.short(m.swapUsed), color: m.swapUsed > m.total * 0.25 ? .orange : .primary)
                Metric(label: "换入/换出", value: String(format: "%.0f/%.0f", m.swapInsPerSec, m.swapOutsPerSec),
                       color: m.swapOutsPerSec > 50 ? .red : .primary, sub: "页/秒")
                Metric(label: "磁盘读/写", value: ByteFormat.rate(sys.diskReadBps), sub: "写 " + ByteFormat.rate(sys.diskWriteBps))
            }
            StackedBar(total: m.total, segments: [
                .init(label: "应用", value: m.app, color: .blue),
                .init(label: "联动", value: m.wired, color: .orange),
                .init(label: "已压缩", value: m.compressed, color: .yellow),
            ])
        }
    }
}
