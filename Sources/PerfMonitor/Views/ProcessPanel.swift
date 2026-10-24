import AppKit
import SwiftUI

enum ProcessViewMode: String, CaseIterable, Identifiable {
    case flat, apps, tree
    var id: String { rawValue }
    var title: String {
        switch self {
        case .flat: "所有进程"
        case .apps: "按应用合并"
        case .tree: "层级"
        }
    }
}

enum ProcessFilter: String, CaseIterable, Identifiable {
    case all, mine, system, others, windowed, active, gpu
    var id: String { rawValue }
    var title: String {
        switch self {
        case .all: "全部"
        case .mine: "我的进程"
        case .system: "系统进程"
        case .others: "其他用户"
        case .windowed: "有窗口的"
        case .active: "活跃的"
        case .gpu: "使用 GPU 的"
        }
    }

    func includes(_ p: ProcessStat, me: uid_t) -> Bool {
        switch self {
        case .all: true
        case .mine: p.uid == me
        case .system: p.uid < 500
        case .others: p.uid != me && p.uid >= 500
        case .windowed: p.hasWindow
        case .active: p.cpu > 0.05
        case .gpu: p.gpuTime != nil
        }
    }
}

/// Activity Monitor–style process browser: tabs, view modes, filters, native table, summary.
struct ProcessPanel: View {
    @Environment(Monitor.self) private var monitor
    @Environment(\.openWindow) private var openWindow
    @AppStorage("processTab") private var tab = ProcessTab.cpu
    @AppStorage("processMode") private var mode = ProcessViewMode.apps
    @AppStorage("processFilter") private var filter = ProcessFilter.all
    @State private var query = ""
    @State private var pendingKill: ProcessStat?

    private var rows: [ProcessStat] {
        let s = monitor.dashboard
        let me = getuid()
        var list = mode == .apps ? s.apps : s.processes
        if filter != .all { list = list.filter { filter.includes($0, me: me) } }
        if !query.isEmpty {
            list = list.filter { $0.name.localizedCaseInsensitiveContains(query) || $0.pids.contains { "\($0)" == query } }
        }
        return list
    }

    var body: some View {
        let rows = rows
        VStack(spacing: 0) {
            VStack(spacing: 6) {
                Picker("", selection: $tab) {
                    ForEach(ProcessTab.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented).labelsHidden()
                HStack(spacing: 6) {
                    Picker("", selection: $mode) {
                        ForEach(ProcessViewMode.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    Picker("", selection: $filter) {
                        ForEach(ProcessFilter.allCases) { Text($0.title).tag($0) }
                    }
                    .labelsHidden().fixedSize()
                    Text("\(rows.count) 项").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    TextField("名称或 PID", text: $query).textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 120)
                }
                .controlSize(.small)
            }
            .padding(.horizontal, 8).padding(.vertical, 6)

            ProcessTableView(
                rows: rows, tab: tab, tree: mode == .tree && query.isEmpty,
                actions: ProcessTableActions(
                    open: { openWindow(value: InspectorTarget(pid: $0.pids.first ?? 0, sample: false)) },
                    sample: { openWindow(value: InspectorTarget(pid: $0.pids.first ?? 0, sample: true)) },
                    confirmKill: { pendingKill = $0 }
                )
            )

            Divider()
            SummaryBar(tab: tab)
                .padding(.horizontal, 8).padding(.vertical, 5)
        }
        .onAppear { monitor.wantsNetwork = tab == .network }
        .onChange(of: tab) { monitor.wantsNetwork = tab == .network }
        .onDisappear { monitor.wantsNetwork = false }
        .alert("强制退出 \(pendingKill?.name ?? "")？", isPresented: Binding(get: { pendingKill != nil }, set: { if !$0 { pendingKill = nil } })) {
            Button("强制退出", role: .destructive) {
                if let p = pendingKill { ProcessActions.terminate(p.pids, force: true) }
                pendingKill = nil
            }
            Button("取消", role: .cancel) { pendingKill = nil }
        } message: {
            Text("未保存的内容会丢失。")
        }
    }
}

/// Totals under the table, like the bottom strip of Activity Monitor.
private struct SummaryBar: View {
    @Environment(Monitor.self) private var monitor
    let tab: ProcessTab

    var body: some View {
        let s = monitor.dashboard
        let all = s.processes
        let items: [String] = switch tab {
        case .cpu: [
            String(format: "系统 %.1f%%", s.system.cpuSystem * 100),
            String(format: "用户 %.1f%%", s.system.cpuUser * 100),
            String(format: "空闲 %.1f%%", (1 - s.system.cpuTotal) * 100),
            "线程 \(all.reduce(0) { $0 + max($1.threads, 0) })",
            "进程 \(all.count)",
        ]
        case .memory: [
            "已用 \(ByteFormat.short(s.system.memory.used)) / \(ByteFormat.short(s.system.memory.total))",
            "应用 \(ByteFormat.short(s.system.memory.app))",
            "联动 \(ByteFormat.short(s.system.memory.wired))",
            "已压缩 \(ByteFormat.short(s.system.memory.compressed))",
            "交换 \(ByteFormat.short(s.system.memory.swapUsed))",
        ]
        case .energy: [
            "整机 " + Fmt.watts(s.totalW),
            "CPU " + Fmt.watts(s.io.cpuW),
            "GPU " + Fmt.watts(s.io.gpuW),
            s.power.hasBattery ? "电量 " + Fmt.pct(s.power.percent) + (s.power.onAC ? "（电源）" : "（电池）") : "",
            "阻止睡眠 \(all.filter(\.preventingSleep).count) 个",
        ]
        case .disk: [
            "整盘读取 " + ByteFormat.rate(s.system.diskReadBps),
            "写入 " + ByteFormat.rate(s.system.diskWriteBps),
            "进程列只统计你自己的进程",
        ]
        case .network: [
            "接收 " + ByteFormat.rate(all.reduce(0) { $0 + ($1.netInBps ?? 0) }),
            "发送 " + ByteFormat.rate(all.reduce(0) { $0 + ($1.netOutBps ?? 0) }),
            "数据来自 nettop，仅在此页打开时采集",
        ]
        }
        Text(items.filter { !$0.isEmpty }.joined(separator: "   "))
            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
            .lineLimit(1).truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct AppIcon: View {
    let path: String?
    var body: some View {
        Image(nsImage: AppIconCache.icon(path)).resizable().frame(width: 14, height: 14)
    }
}
