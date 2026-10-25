import AppKit
import SwiftUI

final class AppDelegate: NSObject, NSApplicationDelegate {
    let monitor = Monitor()
    private var server: HTTPServer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        server = HTTPServer(source: monitor)
        server?.start()
        FloatingPanelController.shared.attach(monitor)
    }

    // Closing the dashboard keeps the menu bar item running.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    /// Set by a always-alive view so AppKit code can open the SwiftUI dashboard window.
    static var openDashboard: (() -> Void)?

    /// Dock icon clicked. The menu bar item counts as a visible window, so SwiftUI's default
    /// handling assumed a window was already showing and did nothing.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        Self.showDashboard()
        return false
    }

    static func showDashboard() {
        if let w = NSApp.windows.first(where: { $0.identifier?.rawValue.hasPrefix("main") == true && !($0 is NSPanel) }) {
            w.collectionBehavior.insert(.moveToActiveSpace)
            if w.isMiniaturized { w.deminiaturize(nil) }
            w.makeKeyAndOrderFront(nil)
        } else {
            openDashboard?()
        }
        NSApp.activate(ignoringOtherApps: true)
    }
}

struct PerfMonitorApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        Window("性能监控", id: "main") {
            DashboardView().environment(delegate.monitor)
        }
        .defaultSize(width: 1320, height: 900)
        .windowToolbarStyle(.unified(showsTitle: true))

        WindowGroup("进程详情", for: InspectorTarget.self) { $target in
            if let target {
                ProcessInspector(target: target).environment(delegate.monitor)
            }
        }
        .defaultSize(width: 600, height: 560)

        MenuBarExtra {
            MenuBarView().environment(delegate.monitor)
        } label: {
            MenuBarLabel(monitor: delegate.monitor)
        }
        .menuBarExtraStyle(.window)
    }
}

// The same binary is the CLI / MCP server: `perfmon status`, `perfmon mcp`, …
let args = Array(CommandLine.arguments.dropFirst()).filter { !$0.hasPrefix("-psn_") && !$0.hasPrefix("-NS") && !$0.hasPrefix("-Apple") }
let invokedAsCLI = (CommandLine.arguments.first as NSString?)?.lastPathComponent == "perfmon"
if !args.isEmpty || invokedAsCLI {
    exit(CLI.run(args))
} else {
    PerfMonitorApp.main()
}
