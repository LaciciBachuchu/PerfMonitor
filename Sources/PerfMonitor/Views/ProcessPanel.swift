import AppKit
import SwiftUI

enum ProcessSortKey: String, CaseIterable {
    case name, cpu, power, memory, disk

    func value(_ p: ProcessStat) -> Double {
        switch self {
        case .name: 0
        case .cpu: p.cpu
        case .power: p.powerW ?? -1
        case .memory: p.memory
        case .disk: p.diskBps
        }
    }
}

/// Process list drawn as fixed-height rows in a LazyVStack. SwiftUI's Table (NSTableView)
/// re-measured every row height on each re-sort, which alone cost ~6% CPU at a 2 s refresh.
struct ProcessPanel: View {
    @Environment(Monitor.self) private var monitor
    @AppStorage("groupByApp") private var grouped = true
    @AppStorage("processSort") private var sortKey = ProcessSortKey.cpu
    @AppStorage("processSortAscending") private var ascending = false
    @State private var query = ""
    @State private var pendingKill: ProcessStat?
    @State private var frozenOrder: [ProcessStat.ID: Int]?

    static let rowHeight: CGFloat = 20
    private static let columns: [(ProcessSortKey, String, CGFloat)] = [(.cpu, "CPU", 58), (.power, "功耗", 64), (.memory, "内存", 62), (.disk, "磁盘", 66)]

    private var rows: [ProcessStat] {
        var list = grouped ? monitor.dashboard.apps : monitor.dashboard.processes
        if !query.isEmpty { list = list.filter { $0.name.localizedCaseInsensitiveContains(query) } }
        if sortKey == .name {
            list.sort { ($0.name.localizedStandardCompare($1.name) == .orderedAscending) == ascending }
        } else {
            list.sort { ascending ? sortKey.value($0) < sortKey.value($1) : sortKey.value($0) > sortKey.value($1) }
        }
        // While hovering, keep the previous row order (values still update) so rows don't jump under the cursor.
        if let order = frozenOrder, !order.isEmpty {
            list.sort { (order[$0.id] ?? .max) < (order[$1.id] ?? .max) }
        }
        return Array(list.prefix(50))
    }

    var body: some View {
        let rows = rows
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(Array(rows.enumerated()), id: \.element.id) { i, p in
                    ProcessRow(p: p, striped: i % 2 == 1)
                        .contextMenu { menu(p) }
                }
            }
        }
        .onHover { inside in
            frozenOrder = inside ? Dictionary(uniqueKeysWithValues: rows.enumerated().map { ($1.id, $0) }) : nil
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            VStack(spacing: 0) {
                HStack {
                    Label("进程", systemImage: "list.bullet.rectangle").font(.subheadline.bold())
                    Text("\(grouped ? monitor.dashboard.apps.count : monitor.dashboard.processes.count)").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Toggle("按应用合并", isOn: $grouped).toggleStyle(.switch).controlSize(.mini).font(.caption)
                    TextField("搜索", text: $query).textFieldStyle(.roundedBorder).controlSize(.small).frame(width: 120)
                }
                .padding(.horizontal, 10).padding(.vertical, 8)
                header
                Divider()
            }
            .background(.background)
        }
        .safeAreaInset(edge: .bottom, spacing: 0) {
            Text("功耗为内核记账的进程 CPU 能耗（不含 GPU 和屏幕）；带「≈」的是系统进程，按 CPU 时间估算。鼠标悬停时暂停重新排序；右键可限制到能效核或结束进程。")
                .font(.system(size: 9.5)).foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(8)
                .background(.background)
        }
        .alert("强制结束 \(pendingKill?.name ?? "")？", isPresented: Binding(get: { pendingKill != nil }, set: { if !$0 { pendingKill = nil } })) {
            Button("强制结束", role: .destructive) {
                if let p = pendingKill { ProcessActions.terminate(p.pids, force: true) }
                pendingKill = nil
            }
            Button("取消", role: .cancel) { pendingKill = nil }
        } message: {
            Text("未保存的内容会丢失。")
        }
    }

    private var header: some View {
        HStack(spacing: 0) {
            headerButton(.name, "名称").frame(maxWidth: .infinity, alignment: .leading).padding(.leading, 30)
            ForEach(Self.columns, id: \.0) { key, title, width in
                headerButton(key, title).frame(width: width, alignment: .trailing)
            }
        }
        .padding(.trailing, 12)
        .frame(height: 20)
    }

    private func headerButton(_ key: ProcessSortKey, _ title: String) -> some View {
        Button {
            if sortKey == key { ascending.toggle() } else { sortKey = key; ascending = key == .name }
            frozenOrder = nil
        } label: {
            HStack(spacing: 2) {
                Text(title)
                if sortKey == key { Image(systemName: ascending ? "chevron.up" : "chevron.down").font(.system(size: 7, weight: .bold)) }
            }
            .font(.caption.bold()).foregroundStyle(sortKey == key ? .primary : .secondary)
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private func menu(_ p: ProcessStat) -> some View {
        Button("限制到能效核（后台优先级）") { ProcessActions.setBackground(p.pids, true) }
        Button("取消限制") { ProcessActions.setBackground(p.pids, false) }
        Divider()
        if let app = p.appPath {
            Button("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app)]) }
        }
        Button("复制 PID") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(p.pids.map(String.init).joined(separator: " "), forType: .string)
        }
        Divider()
        Button("退出") { ProcessActions.terminate(p.pids, force: false) }
        Button("强制结束…", role: .destructive) { pendingKill = p }
    }
}

private struct ProcessRow: View {
    let p: ProcessStat
    let striped: Bool

    var body: some View {
        HStack(spacing: 0) {
            HStack(spacing: 5) {
                AppIcon(path: p.appPath)
                Text(p.name).lineLimit(1).truncationMode(.middle)
                if p.background {
                    Image(systemName: "leaf.fill").font(.system(size: 9)).foregroundStyle(.green).help("已限制到能效核")
                }
                if p.pids.count > 1 { Text("\(p.pids.count)").font(.system(size: 9)).foregroundStyle(.secondary) }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text(String(format: "%.1f%%", p.cpu))
                .foregroundStyle(p.cpu > 80 ? .red : p.cpu > 30 ? .orange : .primary)
                .frame(width: 58, alignment: .trailing)
            Text(Fmt.procWatts(p)).foregroundStyle(p.powerEstimated ? .secondary : .primary)
                .frame(width: 64, alignment: .trailing)
            Text(ByteFormat.short(p.memory)).frame(width: 62, alignment: .trailing)
            Text(p.diskBps > 1024 ? ByteFormat.rate(p.diskBps) : "—").foregroundStyle(p.diskBps > 1024 ? .primary : .tertiary)
                .frame(width: 66, alignment: .trailing)
        }
        .font(.caption.monospacedDigit())
        .padding(.leading, 10).padding(.trailing, 12)
        .frame(height: ProcessPanel.rowHeight)
        .background(striped ? Color.primary.opacity(0.035) : .clear)
        .contentShape(Rectangle())
    }
}

struct AppIcon: View {
    let path: String?
    private static var cache: [String: NSImage] = [:]

    var body: some View {
        if let path {
            Image(nsImage: Self.icon(path)).frame(width: 14, height: 14)
        } else {
            Image(systemName: "gearshape").font(.system(size: 10)).frame(width: 14, height: 14).foregroundStyle(.secondary)
        }
    }

    /// Icons are rasterised once at 32 px; resampling the full icon each refresh was the top CPU cost.
    private static func icon(_ path: String) -> NSImage {
        if let i = cache[path] { return i }
        let src = NSWorkspace.shared.icon(forFile: path)
        let size = NSSize(width: 32, height: 32)
        let i = NSImage(size: size, flipped: false) { rect in
            src.draw(in: rect)
            return true
        }
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            src.draw(in: NSRect(origin: .zero, size: size))
            NSGraphicsContext.restoreGraphicsState()
            let out = NSImage(size: NSSize(width: 16, height: 16))
            out.addRepresentation(rep)
            cache[path] = out
            return out
        }
        cache[path] = i
        return i
    }
}
