import AppKit
import SwiftUI

struct DashboardView: View {
    @Environment(Monitor.self) private var monitor
    @AppStorage("showProcesses") private var showProcesses = true
    @State private var status = PowerStatus()

    var body: some View {
        Group {
            if monitor.dashboardActive {
                DashboardContent(status: status)
            } else {
                // Window closed/minimized/covered: drop the whole view tree to free its memory.
                Color.clear
            }
        }
        .frame(minWidth: 640, minHeight: 520)
        .background(WindowBackdrop().ignoresSafeArea())
        .background(WindowVisibilityReader { monitor.dashboardVisible = $0 })
        .inspector(isPresented: $showProcesses) {
            Group {
                if monitor.dashboardActive { ProcessPanel() } else { Color.clear }
            }
            .inspectorColumnWidth(min: 380, ideal: 560, max: 1000)
        }
        .toolbar { DashboardToolbar(status: status, showProcesses: $showProcesses) }
        .navigationTitle("性能监控")
        .navigationSubtitle(Host.current().localizedName ?? "Mac")
    }
}

/// Status of a pending power-mode change, shown as a banner above the cards.
@Observable
final class PowerStatus {
    var busy = false
    var message: String?
}

/// Cards fill the window; only when the window is too small to fit them does the area scroll.
private struct DashboardContent: View {
    @Environment(Monitor.self) private var monitor
    let status: PowerStatus

    var body: some View {
        GeometryReader { g in
            let columns = g.size.width >= 1050 ? 3 : 2
            ViewThatFits(in: .vertical) {
                content(columns: columns, expand: true)
                    .frame(width: g.size.width, height: g.size.height, alignment: .top)
                ScrollView {
                    content(columns: columns, expand: false)
                        .frame(width: g.size.width)
                }
            }
        }
    }

    @ViewBuilder
    private func content(columns: Int, expand: Bool) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            if status.busy || status.message != nil {
                Label(status.busy ? "请在系统授权窗口中输入 Mac 登录密码…" : status.message!,
                      systemImage: status.busy ? "lock" : "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(status.busy ? .orange : .red)
            }
            FindingsView(findings: monitor.findings)
                .fixedSize(horizontal: false, vertical: true)
            GlassGroup {
                VStack(spacing: 10) {
                    if columns == 3 {
                        row(expand) { ThermalCard(); PowerCard(); ChargingCard() }
                        row(expand) { CPUCard(); GPUCard(); MemoryCard() }
                    } else {
                        row(expand) { ThermalCard(); PowerCard() }
                        row(expand) { CPUCard(); GPUCard() }
                        row(expand) { MemoryCard(); ChargingCard() }
                    }
                    HardwareCard().fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(12)
    }

    /// A row of equal-height cards that soaks up spare height when `expand` is set.
    private func row<C: View>(_ expand: Bool, @ViewBuilder _ cards: () -> C) -> some View {
        // Spare height goes to the charts (capped at 1.5×); when scrolling, rows take their natural height.
        HStack(alignment: .top, spacing: 10) { cards() }
            .fixedSize(horizontal: false, vertical: !expand)
    }
}

/// The desktop shows through a blurred window background, like Control Center and widgets.
struct WindowBackdrop: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let v = NSVisualEffectView()
        v.material = .underWindowBackground
        v.blendingMode = .behindWindow
        v.state = .followsWindowActiveState
        return v
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
}

/// Groups glass shapes so neighbouring cards blend like system glass (macOS 26+).
struct GlassGroup<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        if #available(macOS 26.0, *) {
            GlassEffectContainer(spacing: 10) { content }
        } else {
            content
        }
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

// MARK: - Toolbar

struct DashboardToolbar: ToolbarContent {
    @Environment(Monitor.self) private var monitor
    let status: PowerStatus
    @Binding var showProcesses: Bool
    @State private var showInfo = false
    @AppStorage("floatingPanel") private var floating = false

    var body: some ToolbarContent {
        let ps = monitor.powerState
        ToolbarItemGroup(placement: .primaryAction) {
            ForEach(PowerSource.allCases) { source in
                Picker(source == .battery ? "使用电池时" : "接通电源时",
                       selection: Binding(get: { ps.mode(for: source) }, set: { apply($0, [source]) })) {
                    ForEach(PowerMode.allCases.filter { $0 != .high || ps.supportsHigh }) { Text($0.label).tag($0) }
                }
                .pickerStyle(.segmented)
                .controlSize(.large)
                .help(source == .battery ? "使用电池时的性能档位" : "接通电源时的性能档位")
                .overlay(alignment: .leading) {
                    Image(systemName: source == .battery ? "battery.75percent" : "powerplug")
                        .font(.caption2).foregroundStyle(.secondary).offset(x: -16)
                }
                .padding(.leading, 18)
                .disabled(status.busy)
            }

            Button {
                status.busy = true
                monitor.setPasswordless(!ps.passwordless) { err in status.busy = false; status.message = err }
            } label: {
                Label("免密码", systemImage: ps.passwordless ? "lock.open.fill" : "lock.fill")
            }
            .glassButton()
            .help(ps.passwordless
                  ? "已开启免密码切换（/etc/sudoers.d/perfmonitor，只允许 pmset 低功耗/性能模式命令）。点击可移除。"
                  : "切换档位目前每次都要输入密码。点击做一次授权：以后切换不再需要密码（只放行 pmset 低功耗/性能模式命令）。")
            .disabled(status.busy)

            Button { showInfo.toggle() } label: { Label("档位说明", systemImage: "info.circle") }
                .glassButton()
                .popover(isPresented: $showInfo, arrowEdge: .bottom) { PowerInfo(supportsHigh: ps.supportsHigh) }
        }

        ToolbarItemGroup(placement: .primaryAction) {
            Menu {
                Picker("采样间隔", selection: Binding(get: { monitor.interval }, set: { monitor.setInterval($0) })) {
                    Text("1 秒").tag(1.0)
                    Text("2 秒").tag(2.0)
                    Text("3 秒").tag(3.0)
                }
                .pickerStyle(.inline)
            } label: {
                Label("采样间隔", systemImage: "timer")
            }
            .menuStyle(.button)
            .glassButton()
            .help("采样间隔：\(Int(monitor.interval)) 秒")

            Toggle(isOn: $floating) { Label("悬浮窗", systemImage: "pip") }
                .toggleStyle(.button).glassButton()
                .help("悬浮窗")

            Toggle(isOn: $showProcesses) { Label("进程", systemImage: "sidebar.right") }
                .toggleStyle(.button).glassButton()
                .help("显示或隐藏进程列表")
        }
    }

    private func apply(_ mode: PowerMode, _ sources: [PowerSource]) {
        status.busy = !monitor.powerState.passwordless
        status.message = nil
        monitor.applyPowerMode(mode, sources: sources) { err in status.busy = false; status.message = err }
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
                            .font(.callout).fixedSize(horizontal: false, vertical: true)
                        Text(f.advice).font(.caption).foregroundStyle(.tertiary).fixedSize(horizontal: false, vertical: true)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 6).padding(.horizontal, 10)
                .cardBackground(cornerRadius: 12, tint: Palette.severity(f.severity))
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
        Card("温度", icon: "thermometer.medium", hero: Fmt.temp(s.socTemp), heroColor: Palette.temp(s.socTemp), heroValue: s.socTemp ?? 0) {
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
                Metric(label: "SoC 最高", value: Fmt.temp(s.sensors.soc?.max), color: Palette.temp(s.sensors.soc?.max))
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
        Card("整机功耗", icon: "bolt.fill", hero: String(format: "%.1f W", s.totalW), heroValue: s.totalW) {
            EmptyView()
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
        Card("CPU", icon: "cpu", hero: Fmt.pct(s.system.cpuTotal), heroColor: Palette.load(s.system.cpuTotal), heroValue: s.system.cpuTotal) {
            EmptyView()
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
        Card("GPU", icon: "square.stack.3d.up.fill", hero: Fmt.pct(s.gpuUtil), heroColor: Palette.load(s.gpuUtil), heroValue: s.gpuUtil) {
            EmptyView()
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
        Card("内存与磁盘", icon: "memorychip", hero: ByteFormat.short(m.used), heroColor: color == .green ? .primary : color, heroValue: m.used) {
            Text("压力 \(label)").font(.caption2.bold())
                .padding(.horizontal, 6).padding(.vertical, 1)
                .background(color.opacity(0.18), in: Capsule()).foregroundStyle(color)
        } content: {
            HStack(spacing: 4) {
                Metric(label: "总内存", value: ByteFormat.short(m.total), sub: String(format: "已用 %.0f%%", m.used / max(m.total, 1) * 100))
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
            let h = monitor.history
            Sparkline(series: [
                .init(name: "已用 GB", color: .blue, values: h.map(\.memUsed), fill: true),
                .init(name: "已压缩 GB", color: .yellow, values: h.map(\.memCompressed)),
                .init(name: "交换 GB", color: .orange, values: h.map(\.swapUsed)),
            ], range: 0...max(m.total / 1_073_741_824, (h.map(\.swapUsed).max() ?? 0) + 0.5), unit: "G")
        }
    }
}
