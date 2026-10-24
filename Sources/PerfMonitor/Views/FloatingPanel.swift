import AppKit
import SwiftUI

/// Always-on-top mini monitor. Non-activating, so clicking it never steals focus.
final class FloatingPanelController {
    static let shared = FloatingPanelController()
    static let defaultsKey = "floatingPanel"

    private var panel: NSPanel?
    private weak var monitor: Monitor?
    private var observer: NSObjectProtocol?

    func attach(_ monitor: Monitor) {
        self.monitor = monitor
        sync()
        observer = NotificationCenter.default.addObserver(forName: UserDefaults.didChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.sync()
        }
    }

    private func sync() {
        let on = UserDefaults.standard.bool(forKey: Self.defaultsKey)
        if on, panel == nil { show() } else if !on, let p = panel { p.close(); panel = nil }
    }

    private func show() {
        guard let monitor else { return }
        let p = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 230, height: 150),
                        styleMask: [.nonactivatingPanel, .borderless, .fullSizeContentView],
                        backing: .buffered, defer: false)
        p.isFloatingPanel = true
        p.level = .floating
        p.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        p.isMovableByWindowBackground = true
        p.backgroundColor = .clear
        p.isOpaque = false
        p.hasShadow = true
        p.hidesOnDeactivate = false
        let host = NSHostingView(rootView: FloatingView().environment(monitor))
        host.sizingOptions = [.preferredContentSize]
        p.contentView = host
        // Assign before autosaving: saving the frame writes defaults, which re-enters sync().
        panel = p
        p.setFrameAutosaveName("PerfMonitorFloatingPanel")
        if !p.setFrameUsingName("PerfMonitorFloatingPanel"), let screen = NSScreen.main {
            p.setFrameTopLeftPoint(NSPoint(x: screen.visibleFrame.maxX - 250, y: screen.visibleFrame.maxY - 20))
        }
        p.orderFrontRegardless()
    }
}

struct FloatingView: View {
    @Environment(Monitor.self) private var monitor
    @AppStorage(FloatingPanelController.defaultsKey) private var floating = true

    var body: some View {
        let s = monitor.snapshot
        let top = s.apps.max { $0.cpu < $1.cpu }
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(Palette.thermal(s.system.thermal)).frame(width: 7, height: 7)
                Text("热压力 \(s.system.thermal.label)").font(.caption2).foregroundStyle(.secondary)
                Spacer()
                Button { floating = false } label: { Image(systemName: "xmark").font(.caption2) }
                    .buttonStyle(.borderless).foregroundStyle(.secondary)
            }
            HStack(alignment: .firstTextBaseline, spacing: 12) {
                stat(Fmt.temp(s.socTemp), "SoC", Palette.temp(s.socTemp))
                stat(String(format: "%.1fW", s.totalW), "整机", .primary)
                stat(Fmt.pct(s.system.cpuTotal), "CPU", Palette.load(s.system.cpuTotal))
                stat(Fmt.pct(s.gpuUtil), "GPU", Palette.load(s.gpuUtil))
            }
            HStack(spacing: 10) {
                Text(String(format: "CPU %.1fW", s.io.cpuW))
                Text("P核 " + Fmt.mhz(s.io.pCluster.freqMHz))
                Text("内存 " + ByteFormat.short(s.system.memory.used))
            }
            .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            if s.power.batteryW > 0.05 || s.power.portsOutW > 0 {
                HStack(spacing: 10) {
                    if s.power.batteryW > 0.05 { Text(String(format: "充电 %.1fW", s.power.batteryW)) }
                    if s.power.portsOutW > 0 { Text(String(format: "对外 %.1fW", s.power.portsOutW)) }
                }
                .font(.caption2).foregroundStyle(.secondary).monospacedDigit()
            }
            if let f = s.findings.first, f.kind != .idle {
                Text(f.title).font(.caption.bold()).foregroundStyle(Palette.severity(f.severity)).lineLimit(1)
            } else if let top {
                Text("最忙：\(top.name) \(String(format: "%.0f%%", top.cpu))").font(.caption).lineLimit(1)
            }
        }
        .padding(10)
        .frame(width: 240, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color(nsColor: .windowBackgroundColor).opacity(0.92)))
        .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous).strokeBorder(.separator))
    }

    private func stat(_ value: String, _ label: String, _ color: Color) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(value).font(.system(.callout, design: .rounded).weight(.semibold)).foregroundStyle(color).monospacedDigit()
            Text(label).font(.caption2).foregroundStyle(.secondary)
        }
    }
}
