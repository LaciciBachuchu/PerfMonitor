import SwiftUI

struct MenuBarLabel: View {
    var monitor: Monitor

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: monitor.menuBarHot ? "flame.fill" : "thermometer.medium")
            Text(monitor.menuBarText).monospacedDigit()
        }
    }
}

struct MenuBarView: View {
    @Environment(Monitor.self) private var monitor
    @Environment(\.openWindow) private var openWindow
    @AppStorage(FloatingPanelController.defaultsKey) private var floating = false

    var body: some View {
        let s = monitor.snapshot
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Metric(label: "SoC", value: Fmt.temp(s.socTemp), color: Palette.temp(s.socTemp))
                Metric(label: "功耗", value: Fmt.watts(s.totalW))
                Metric(label: "CPU", value: Fmt.pct(s.system.cpuTotal), color: Palette.load(s.system.cpuTotal))
                Metric(label: "GPU", value: Fmt.pct(s.system.gpuUtil ?? s.io.gpu.active))
            }
            HStack(spacing: 6) {
                Circle().fill(Palette.thermal(s.system.thermal)).frame(width: 8, height: 8)
                Text("热压力 \(s.system.thermal.label)")
                Spacer()
                Text("P 核 \(Fmt.mhz(s.io.pCluster.freqMHz))").monospacedDigit()
            }
            .font(.caption)

            if let f = monitor.findings.first {
                VStack(alignment: .leading, spacing: 3) {
                    Text(f.title).font(.subheadline.bold()).foregroundStyle(Palette.severity(f.severity))
                    Text(f.detail).font(.caption).foregroundStyle(.secondary).lineLimit(3)
                }
            }

            Divider()
            Text("占用最高").font(.caption).foregroundStyle(.secondary)
            ForEach(s.apps.sorted { $0.cpu > $1.cpu }.prefix(5)) { p in
                HStack(spacing: 6) {
                    AppIcon(path: p.appPath)
                    Text(p.name).lineLimit(1)
                    Spacer()
                    Text(String(format: "%.0f%%", p.cpu)).monospacedDigit().foregroundStyle(.secondary)
                    Text(p.powerW.map { String(format: "%.1fW", $0) } ?? "").monospacedDigit().foregroundStyle(.secondary).frame(width: 44, alignment: .trailing)
                }
                .font(.callout)
            }

            Divider()
            HStack {
                Button("打开监控面板") {
                    openWindow(id: "main")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Toggle("悬浮窗", isOn: $floating).toggleStyle(.checkbox)
                Spacer()
                Button("退出") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 340)
    }
}
