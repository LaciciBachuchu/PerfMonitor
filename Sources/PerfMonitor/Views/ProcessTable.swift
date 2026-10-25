import AppKit
import SwiftUI

// MARK: - Tabs and columns

enum ProcessTab: String, CaseIterable, Identifiable {
    case cpu, memory, energy, disk, network
    var id: String { rawValue }

    var title: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "内存"
        case .energy: "能耗"
        case .disk: "磁盘"
        case .network: "网络"
        }
    }

    var columns: [PColumn] {
        switch self {
        case .cpu: [.name, .cpu, .cpuTime, .threads, .wakeups, .gpu, .gpuTime, .kind, .pid, .ppid, .user, .started]
        case .memory: [.name, .memory, .resident, .peak, .threads, .kind, .pid, .ppid, .user]
        case .energy: [.name, .power, .avgPower, .energy, .wakeups, .sleep, .cpu, .gpu, .kind, .pid, .user]
        case .disk: [.name, .readRate, .writeRate, .readTotal, .writeTotal, .pid, .user]
        case .network: [.name, .netIn, .netOut, .netInTotal, .netOutTotal, .pid, .user]
        }
    }

    var defaultHidden: Set<PColumn> {
        switch self {
        case .cpu: [.gpuTime, .kind, .ppid, .started]
        case .memory: [.kind, .ppid]
        case .energy: [.energy, .gpu, .kind, .pid]
        case .disk, .network: []
        }
    }

    var defaultSort: PColumn {
        switch self {
        case .cpu: .cpu
        case .memory: .memory
        case .energy: .power
        case .disk: .writeRate
        case .network: .netIn
        }
    }
}

enum PColumn: String, CaseIterable {
    case name, cpu, cpuTime, threads, wakeups, gpu, gpuTime, kind, pid, ppid, user, started
    case memory, resident, peak
    case power, avgPower, energy, sleep
    case readRate, writeRate, readTotal, writeTotal
    case netIn, netOut, netInTotal, netOutTotal

    var title: String {
        switch self {
        case .name: "进程名称"
        case .cpu: "% CPU"
        case .cpuTime: "CPU 时间"
        case .threads: "线程"
        case .wakeups: "空闲唤醒"
        case .gpu: "% GPU"
        case .gpuTime: "GPU 时间"
        case .kind: "种类"
        case .pid: "PID"
        case .ppid: "父 PID"
        case .user: "用户"
        case .started: "启动时间"
        case .memory: "内存"
        case .resident: "实际内存"
        case .peak: "峰值内存"
        case .power: "功耗"
        case .avgPower: "平均功耗"
        case .energy: "累计能耗"
        case .sleep: "阻止睡眠"
        case .readRate: "读取/秒"
        case .writeRate: "写入/秒"
        case .readTotal: "已读取"
        case .writeTotal: "已写入"
        case .netIn: "接收/秒"
        case .netOut: "发送/秒"
        case .netInTotal: "已接收"
        case .netOutTotal: "已发送"
        }
    }

    var help: String {
        switch self {
        case .wakeups: "每秒把 CPU 从空闲状态唤醒的次数，越高越费电（仅限你自己的进程）"
        case .memory: "内存占用（phys footprint，与活动监视器的“内存”列一致）；其他用户的进程显示常驻内存"
        case .resident: "当前驻留在物理内存中的大小"
        case .peak: "进程启动以来的最高内存占用（仅限你自己的进程）"
        case .power: "最近一次采样的 CPU 功耗；带 ≈ 的按 CPU 时间估算"
        case .avgPower: "自进程启动以来的平均 CPU 功耗"
        case .energy: "自进程启动以来累计消耗的 CPU 能量"
        case .sleep: "持有电源断言、阻止 Mac 或显示器进入睡眠"
        case .kind: "Apple 芯片原生 或 Intel（通过 Rosetta 转译运行）"
        case .gpu: "最近一次采样中使用 GPU 的时间占比"
        default: title
        }
    }

    var width: CGFloat {
        switch self {
        case .name: 190
        case .user: 74
        case .started: 110
        case .kind: 58
        case .sleep: 60
        case .pid, .ppid, .threads: 52
        default: 70
        }
    }

    var numeric: Bool { ![.name, .user, .kind, .started, .sleep].contains(self) }
    var isText: Bool { [.name, .user, .kind].contains(self) }

    func text(_ p: ProcessStat) -> String {
        switch self {
        case .name: p.name + (p.pids.count > 1 ? "  (\(p.pids.count))" : "")
        case .cpu: String(format: "%.1f", p.cpu)
        case .cpuTime: Fmt.duration(p.cpuTime)
        case .threads: p.threads >= 0 ? "\(p.threads)" : "—"
        case .wakeups: p.idleWakeups.map { String(format: "%.0f", $0) } ?? "—"
        case .gpu: p.gpu.map { String(format: "%.1f", $0) } ?? "—"
        case .gpuTime: p.gpuTime.map { Fmt.duration($0) } ?? "—"
        case .kind: p.translated ? "Intel" : "Apple"
        case .pid: p.pids.count == 1 ? "\(p.pids[0])" : "—"
        case .ppid: "\(p.ppid)"
        case .user: p.user
        case .started: p.startTime.map { Fmt.startTime($0) } ?? "—"
        case .memory: ByteFormat.short(p.memory)
        case .resident: ByteFormat.short(p.resident)
        case .peak: p.peakMemory.map { ByteFormat.short($0) } ?? "—"
        case .power: Fmt.procWatts(p)
        case .avgPower: p.avgPowerW.map { String(format: "%.2f W", $0) } ?? "—"
        case .energy: p.energyJ.map { Fmt.energy($0) } ?? "—"
        case .sleep: p.preventingSleep ? "是" : "否"
        case .readRate: p.isOwn || p.pids.count > 1 ? ByteFormat.rate(p.diskReadBps) : "—"
        case .writeRate: p.isOwn || p.pids.count > 1 ? ByteFormat.rate(p.diskWriteBps) : "—"
        case .readTotal: p.diskRead.map { ByteFormat.short($0) } ?? "—"
        case .writeTotal: p.diskWritten.map { ByteFormat.short($0) } ?? "—"
        case .netIn: p.netInBps.map { ByteFormat.rate($0) } ?? "—"
        case .netOut: p.netOutBps.map { ByteFormat.rate($0) } ?? "—"
        case .netInTotal: p.netIn.map { ByteFormat.short($0) } ?? "—"
        case .netOutTotal: p.netOut.map { ByteFormat.short($0) } ?? "—"
        }
    }

    /// Numeric sort key; text columns sort by `textKey`.
    func value(_ p: ProcessStat) -> Double {
        switch self {
        case .cpu: p.cpu
        case .cpuTime: p.cpuTime
        case .threads: Double(p.threads)
        case .wakeups: p.idleWakeups ?? -1
        case .gpu: p.gpu ?? -1
        case .gpuTime: p.gpuTime ?? -1
        case .pid: Double(p.pids.first ?? 0)
        case .ppid: Double(p.ppid)
        case .started: p.startTime?.timeIntervalSince1970 ?? 0
        case .memory: p.memory
        case .resident: p.resident
        case .peak: p.peakMemory ?? -1
        case .power: p.powerW ?? -1
        case .avgPower: p.avgPowerW ?? -1
        case .energy: p.energyJ ?? -1
        case .sleep: p.preventingSleep ? 1 : 0
        case .readRate: p.diskReadBps
        case .writeRate: p.diskWriteBps
        case .readTotal: p.diskRead ?? -1
        case .writeTotal: p.diskWritten ?? -1
        case .netIn: p.netInBps ?? -1
        case .netOut: p.netOutBps ?? -1
        case .netInTotal: p.netIn ?? -1
        case .netOutTotal: p.netOut ?? -1
        case .name, .user, .kind: 0
        }
    }

    func textKey(_ p: ProcessStat) -> String? {
        switch self {
        case .name: p.name
        case .user: p.user
        case .kind: p.translated ? "Intel" : "Apple"
        default: nil
        }
    }
}

// MARK: - Column settings (per tab, persisted)

enum ColumnPrefs {
    static func hidden(_ tab: ProcessTab) -> Set<PColumn> {
        guard let raw = UserDefaults.standard.array(forKey: "cols.hidden.\(tab.rawValue)") as? [String] else { return tab.defaultHidden }
        return Set(raw.compactMap(PColumn.init))
    }

    static func setHidden(_ cols: Set<PColumn>, _ tab: ProcessTab) {
        UserDefaults.standard.set(cols.map(\.rawValue), forKey: "cols.hidden.\(tab.rawValue)")
    }

    static func width(_ c: PColumn, _ tab: ProcessTab) -> CGFloat {
        let w = UserDefaults.standard.double(forKey: "cols.width.\(tab.rawValue).\(c.rawValue)")
        return w > 0 ? w : c.width
    }

    static func setWidth(_ w: CGFloat, _ c: PColumn, _ tab: ProcessTab) {
        UserDefaults.standard.set(Double(w), forKey: "cols.width.\(tab.rawValue).\(c.rawValue)")
    }

    static func sort(_ tab: ProcessTab) -> (PColumn, Bool) {
        let d = UserDefaults.standard
        let col = d.string(forKey: "cols.sort.\(tab.rawValue)").flatMap(PColumn.init) ?? tab.defaultSort
        let asc = d.object(forKey: "cols.sortAsc.\(tab.rawValue)") as? Bool ?? col.isText
        return (col, asc)
    }

    static func setSort(_ c: PColumn, ascending: Bool, _ tab: ProcessTab) {
        UserDefaults.standard.set(c.rawValue, forKey: "cols.sort.\(tab.rawValue)")
        UserDefaults.standard.set(ascending, forKey: "cols.sortAsc.\(tab.rawValue)")
    }
}

// MARK: - Table

final class ProcessNode: NSObject {
    var stat: ProcessStat
    var children: [ProcessNode] = []
    var id: String { stat.id }
    init(_ s: ProcessStat) { stat = s }
}

struct ProcessTableActions {
    var open: (ProcessStat) -> Void
    var sample: (ProcessStat) -> Void
    var confirmKill: (ProcessStat) -> Void
}

/// AppKit outline view with fixed row heights: a reload only re-renders visible cells, unlike
/// SwiftUI's Table which re-measured every row on each update.
struct ProcessTableView: NSViewRepresentable {
    let rows: [ProcessStat]
    let tab: ProcessTab
    let tree: Bool
    let actions: ProcessTableActions

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSScrollView {
        let outline = HoverOutlineView()
        outline.headerView = NSTableHeaderView()
        outline.rowHeight = 21
        outline.usesAutomaticRowHeights = false
        outline.intercellSpacing = NSSize(width: 6, height: 1)
        outline.style = .plain
        outline.usesAlternatingRowBackgroundColors = true
        outline.allowsMultipleSelection = true
        outline.allowsColumnReordering = true
        outline.allowsColumnResizing = true
        outline.columnAutoresizingStyle = .noColumnAutoresizing
        outline.indentationPerLevel = 12
        outline.autoresizesOutlineColumn = false
        outline.dataSource = context.coordinator
        outline.delegate = context.coordinator
        outline.target = context.coordinator
        outline.doubleAction = #selector(Coordinator.doubleClicked(_:))
        outline.menu = context.coordinator.rowMenu
        outline.headerView?.menu = context.coordinator.headerMenu
        context.coordinator.outline = outline

        let scroll = NSScrollView()
        scroll.documentView = outline
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = false
        return scroll
    }

    func updateNSView(_ nsView: NSScrollView, context: Context) {
        let c = context.coordinator
        c.actions = actions
        if c.tab != tab { c.setTab(tab) }
        c.update(rows, tree: tree)
    }

    final class Coordinator: NSObject, NSOutlineViewDataSource, NSOutlineViewDelegate, NSMenuDelegate {
        weak var outline: HoverOutlineView?
        var tab: ProcessTab?
        var actions: ProcessTableActions?
        let rowMenu = NSMenu()
        let headerMenu = NSMenu()
        private var nodes: [String: ProcessNode] = [:]
        private var roots: [ProcessNode] = []
        private var tree = false
        private var collapsed = Set<String>()
        private var applyingExpansion = false
        private var lastOrder: [String: Int] = [:]
        private var slots: [ProcessNode] = []
        private var slotMode = false

        override init() {
            super.init()
            rowMenu.delegate = self
            headerMenu.delegate = self
        }

        // MARK: Columns

        func setTab(_ t: ProcessTab) {
            guard let outline else { return }
            tab = t
            // NSOutlineView refuses to remove its outline column, so keep the name column and swap the rest.
            for col in outline.tableColumns where col !== outline.outlineTableColumn { outline.removeTableColumn(col) }
            let hidden = ColumnPrefs.hidden(t)
            for c in t.columns {
                if c == .name, let nameCol = outline.outlineTableColumn {
                    nameCol.width = ColumnPrefs.width(c, t)
                    continue
                }
                let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(c.rawValue))
                col.title = c.title
                col.headerToolTip = c.help
                col.width = ColumnPrefs.width(c, t)
                col.minWidth = c == .name ? 90 : 36
                col.isHidden = hidden.contains(c) && c != .name
                col.sortDescriptorPrototype = NSSortDescriptor(key: c.rawValue, ascending: c.isText)
                col.headerCell.alignment = c.numeric ? .right : .left
                outline.addTableColumn(col)
                if c == .name { outline.outlineTableColumn = col }
            }
            let (key, asc) = ColumnPrefs.sort(t)
            outline.sortDescriptors = [NSSortDescriptor(key: key.rawValue, ascending: asc)]
            lastOrder = [:]
            slotMode = false
        }

        func outlineViewColumnDidResize(_ notification: Notification) {
            guard let tab, let col = notification.userInfo?["NSTableColumn"] as? NSTableColumn,
                  let c = PColumn(rawValue: col.identifier.rawValue) else { return }
            ColumnPrefs.setWidth(col.width, c, tab)
        }

        func outlineView(_ outlineView: NSOutlineView, sortDescriptorsDidChange oldDescriptors: [NSSortDescriptor]) {
            guard let tab, let d = outlineView.sortDescriptors.first, let c = PColumn(rawValue: d.key ?? "") else { return }
            ColumnPrefs.setSort(c, ascending: d.ascending, tab)
            lastOrder = [:]
            slotMode = false
            resortAndReload()
        }

        // MARK: Data

        private var current: [ProcessStat] = []

        func update(_ rows: [ProcessStat], tree: Bool) {
            current = rows
            if tree != self.tree { self.tree = tree; lastOrder = [:] }
            resortAndReload()
        }

        private func resortAndReload() {
            guard let outline else { return }
            var fresh: [String: ProcessNode] = [:]
            for s in current {
                let n = nodes[s.id] ?? ProcessNode(s)
                n.stat = s
                n.children = []
                fresh[s.id] = n
            }
            nodes = fresh

            var top: [ProcessNode] = []
            if tree {
                var byPID: [pid_t: ProcessNode] = [:]
                for n in fresh.values where n.stat.pids.count == 1 { byPID[n.stat.pids[0]] = n }
                for n in fresh.values {
                    if let parent = byPID[n.stat.ppid], parent !== n { parent.children.append(n) } else { top.append(n) }
                }
            } else {
                top = Array(fresh.values)
            }

            let cmp = comparator()
            // Keep rows still while the pointer is over the table so they don't jump under the cursor.
            let frozen = outline.mouseInside && !lastOrder.isEmpty
            func order(_ list: inout [ProcessNode]) {
                if frozen {
                    list.sort { (lastOrder[$0.id] ?? .max, $0.id) < (lastOrder[$1.id] ?? .max, $1.id) }
                } else {
                    list.sort { cmp($0.stat, $1.stat) }
                }
                for n in list where !n.children.isEmpty { order(&n.children) }
            }
            order(&top)
            roots = top
            if !frozen {
                var i = 0
                func record(_ list: [ProcessNode]) { for n in list { lastOrder[n.id] = i; i += 1; record(n.children) } }
                lastOrder = [:]
                record(top)
            }

            let selectedIDs = Set(outline.selectedRowIndexes.compactMap { (outline.item(atRow: $0) as? ProcessNode)?.id })

            if !tree {
                // Flat list: rows are fixed "slots" whose content changes. Re-sorting rewrites the
                // slots and only a change in count inserts/removes rows, so no cell is ever rebuilt
                // (NSOutlineView doesn't recycle these cells across reloadData).
                let list = top.map(\.stat)
                if !slotMode {
                    slots = list.map { ProcessNode($0) }
                    roots = slots
                    outline.reloadData()
                    slotMode = true
                } else {
                    if list.count > slots.count {
                        let start = slots.count
                        slots += list[start...].map { ProcessNode($0) }
                        roots = slots
                        outline.insertItems(at: IndexSet(start..<slots.count), inParent: nil, withAnimation: [])
                    } else if list.count < slots.count {
                        let range = list.count..<slots.count
                        slots.removeLast(slots.count - list.count)
                        roots = slots
                        outline.removeItems(at: IndexSet(range), inParent: nil, withAnimation: [])
                    }
                    for (i, st) in list.enumerated() { slots[i].stat = st }
                    refreshVisibleCells()
                }
                let rows = IndexSet(slots.indices.filter { selectedIDs.contains(slots[$0].id) })
                if rows != outline.selectedRowIndexes { outline.selectRowIndexes(rows, byExtendingSelection: false) }
                return
            }
            slotMode = false
            slots = []

            outline.reloadData()
            applyingExpansion = true
            for n in roots { expand(n, in: outline) }
            applyingExpansion = false
            let rows = IndexSet(selectedIDs.compactMap { nodes[$0] }.map { outline.row(forItem: $0) }.filter { $0 >= 0 })
            outline.selectRowIndexes(rows, byExtendingSelection: false)
        }

        private func refreshVisibleCells() {
            guard let outline else { return }
            let visible = outline.rows(in: outline.visibleRect)
            for row in visible.lowerBound..<visible.upperBound {
                guard let node = outline.item(atRow: row) as? ProcessNode else { continue }
                for (ci, col) in outline.tableColumns.enumerated() where !col.isHidden {
                    guard let cell = outline.view(atColumn: ci, row: row, makeIfNecessary: false) as? ProcessCell,
                          let c = PColumn(rawValue: col.identifier.rawValue) else { continue }
                    fill(cell, c, node.stat)
                }
            }
        }

        private func expand(_ n: ProcessNode, in outline: NSOutlineView) {
            guard !n.children.isEmpty, !collapsed.contains(n.id) else { return }
            outline.expandItem(n)
            for c in n.children { expand(c, in: outline) }
        }

        private func comparator() -> (ProcessStat, ProcessStat) -> Bool {
            let d = outline?.sortDescriptors.first
            let col = PColumn(rawValue: d?.key ?? "") ?? .cpu
            let asc = d?.ascending ?? false
            return { a, b in
                if let ka = col.textKey(a), let kb = col.textKey(b) {
                    let r = ka.localizedStandardCompare(kb)
                    return asc ? r == .orderedAscending : r == .orderedDescending
                }
                let va = col.value(a), vb = col.value(b)
                return va == vb ? a.id < b.id : (asc ? va < vb : va > vb)
            }
        }

        func outlineView(_ outlineView: NSOutlineView, numberOfChildrenOfItem item: Any?) -> Int {
            (item as? ProcessNode)?.children.count ?? roots.count
        }

        func outlineView(_ outlineView: NSOutlineView, child index: Int, ofItem item: Any?) -> Any {
            (item as? ProcessNode)?.children[index] ?? roots[index]
        }

        func outlineView(_ outlineView: NSOutlineView, isItemExpandable item: Any) -> Bool {
            !((item as? ProcessNode)?.children.isEmpty ?? true)
        }

        func outlineViewItemDidCollapse(_ notification: Notification) {
            guard !applyingExpansion, let n = notification.userInfo?["NSObject"] as? ProcessNode else { return }
            collapsed.insert(n.id)
        }

        func outlineViewItemDidExpand(_ notification: Notification) {
            guard !applyingExpansion, let n = notification.userInfo?["NSObject"] as? ProcessNode else { return }
            collapsed.remove(n.id)
        }

        // MARK: Cells

        private static let font = NSFont.monospacedDigitSystemFont(ofSize: 11.5, weight: .regular)

        func outlineView(_ outlineView: NSOutlineView, viewFor tableColumn: NSTableColumn?, item: Any) -> NSView? {
            guard let tableColumn, let node = item as? ProcessNode, let c = PColumn(rawValue: tableColumn.identifier.rawValue) else { return nil }
            let id = NSUserInterfaceItemIdentifier(c == .name ? "nameCell" : (c.numeric ? "numCell" : "textCell"))
            let cell = (outlineView.makeView(withIdentifier: id, owner: nil) as? ProcessCell) ?? ProcessCell(identifier: id, withIcon: c == .name, numeric: c.numeric)
            fill(cell, c, node.stat)
            return cell
        }

        private func fill(_ cell: ProcessCell, _ c: PColumn, _ s: ProcessStat) {
            var text = c.text(s)
            if c == .name {
                if s.background { text += "  🍃" }
                let img = AppIconCache.icon(s.appPath)
                if cell.icon?.image !== img { cell.icon?.image = img }
                let tip = s.path.isEmpty ? s.name : s.path
                if cell.label.toolTip != tip { cell.label.toolTip = tip }
            }
            if cell.label.stringValue != text { cell.label.stringValue = text }
            let color = color(c, s)
            if cell.label.textColor != color { cell.label.textColor = color }
        }

        private func color(_ c: PColumn, _ s: ProcessStat) -> NSColor {
            switch c {
            case .cpu: s.cpu > 80 ? .systemRed : (s.cpu > 30 ? .systemOrange : .labelColor)
            case .power: s.powerEstimated ? .secondaryLabelColor : .labelColor
            case .sleep: s.preventingSleep ? .systemOrange : .secondaryLabelColor
            case .kind: s.translated ? .systemOrange : .secondaryLabelColor
            case .pid, .ppid, .user, .started: .secondaryLabelColor
            default: c.text(s) == "—" ? .tertiaryLabelColor : .labelColor
            }
        }

        // MARK: Actions

        @objc func doubleClicked(_ sender: NSOutlineView) {
            guard sender.clickedRow >= 0, let n = sender.item(atRow: sender.clickedRow) as? ProcessNode else { return }
            actions?.open(n.stat)
        }

        private func targets() -> [ProcessStat] {
            guard let outline else { return [] }
            let clicked = outline.clickedRow
            let rows = clicked >= 0 && !outline.selectedRowIndexes.contains(clicked) ? IndexSet(integer: clicked) : outline.selectedRowIndexes
            return rows.compactMap { (outline.item(atRow: $0) as? ProcessNode)?.stat }
        }

        func menuNeedsUpdate(_ menu: NSMenu) {
            menu.removeAllItems()
            if menu === headerMenu { buildHeaderMenu(menu) } else { buildRowMenu(menu) }
        }

        private func buildHeaderMenu(_ menu: NSMenu) {
            guard let tab else { return }
            let hidden = ColumnPrefs.hidden(tab)
            for c in tab.columns where c != .name {
                let item = NSMenuItem(title: c.title, action: #selector(toggleColumn(_:)), keyEquivalent: "")
                item.target = self
                item.representedObject = c.rawValue
                item.state = hidden.contains(c) ? .off : .on
                menu.addItem(item)
            }
            menu.addItem(.separator())
            let reset = NSMenuItem(title: "恢复默认列", action: #selector(resetColumns), keyEquivalent: "")
            reset.target = self
            menu.addItem(reset)
        }

        @objc private func toggleColumn(_ sender: NSMenuItem) {
            guard let tab, let raw = sender.representedObject as? String, let c = PColumn(rawValue: raw) else { return }
            var hidden = ColumnPrefs.hidden(tab)
            if hidden.contains(c) { hidden.remove(c) } else { hidden.insert(c) }
            ColumnPrefs.setHidden(hidden, tab)
            outline?.tableColumn(withIdentifier: NSUserInterfaceItemIdentifier(raw))?.isHidden = hidden.contains(c)
            slotMode = false
            resortAndReload()
        }

        @objc private func resetColumns() {
            guard let tab else { return }
            UserDefaults.standard.removeObject(forKey: "cols.hidden.\(tab.rawValue)")
            for c in tab.columns { UserDefaults.standard.removeObject(forKey: "cols.width.\(tab.rawValue).\(c.rawValue)") }
            setTab(tab)
            resortAndReload()
        }

        private func buildRowMenu(_ menu: NSMenu) {
            let t = targets()
            guard let first = t.first else { return }
            let pids = t.flatMap(\.pids)
            func add(_ title: String, _ block: @escaping () -> Void) {
                let item = ClosureMenuItem(title: title, block)
                menu.addItem(item)
            }
            add("显示详情…") { [weak self] in self?.actions?.open(first) }
            add("采样进程…") { [weak self] in self?.actions?.sample(first) }
            menu.addItem(.separator())
            add("限制到能效核（后台优先级）") { ProcessActions.setBackground(pids, true) }
            add("取消限制") { ProcessActions.setBackground(pids, false) }
            menu.addItem(.separator())
            if let app = first.appPath {
                add("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: app)]) }
            } else if !first.path.isEmpty {
                add("在访达中显示") { NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: first.path)]) }
            }
            add("拷贝 PID") { Pasteboard.copy(pids.map(String.init).joined(separator: " ")) }
            if !first.path.isEmpty { add("拷贝路径") { Pasteboard.copy(first.path) } }
            menu.addItem(.separator())
            let signals = NSMenuItem(title: "发送信号", action: nil, keyEquivalent: "")
            let sub = NSMenu()
            for (title, sig) in ProcessActions.signals {
                sub.addItem(ClosureMenuItem(title: title) {
                    if let err = ProcessActions.send(sig, to: pids) { Alerts.info("无法发送信号", "\(err)。其他用户（如系统）的进程需要管理员权限。") }
                })
            }
            signals.submenu = sub
            menu.addItem(signals)
            add("退出") { ProcessActions.terminate(pids, force: false) }
            add("强制退出…") { [weak self] in self?.actions?.confirmKill(first) }
        }
    }
}

final class HoverOutlineView: NSOutlineView {
    private(set) var mouseInside = false
    private var area: NSTrackingArea?

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let area { removeTrackingArea(area) }
        let a = NSTrackingArea(rect: visibleRect, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect], owner: self)
        addTrackingArea(a)
        area = a
    }

    override func mouseEntered(with event: NSEvent) { mouseInside = true }
    override func mouseExited(with event: NSEvent) { mouseInside = false }
}

/// Frame-based cell: no Auto Layout, so creating or reusing one is cheap.
final class ProcessCell: NSTableCellView {
    let label = NSTextField(labelWithString: "")
    var icon: NSImageView?

    init(identifier: NSUserInterfaceItemIdentifier, withIcon: Bool, numeric: Bool) {
        super.init(frame: .zero)
        self.identifier = identifier
        label.font = NSFont.monospacedDigitSystemFont(ofSize: 12.5, weight: .regular)
        label.lineBreakMode = withIcon ? .byTruncatingMiddle : .byTruncatingTail
        label.alignment = numeric ? .right : .left
        label.cell?.truncatesLastVisibleLine = true
        addSubview(label)
        textField = label
        if withIcon {
            let iv = NSImageView()
            iv.imageScaling = .scaleProportionallyUpOrDown
            addSubview(iv)
            icon = iv
        }
    }

    required init?(coder: NSCoder) { fatalError() }

    override func layout() {
        super.layout()
        let h = bounds.height, lh: CGFloat = 17
        if let icon {
            icon.frame = NSRect(x: 0, y: (h - 16) / 2, width: 16, height: 16)
            label.frame = NSRect(x: 20, y: (h - lh) / 2, width: max(bounds.width - 20, 0), height: lh)
        } else {
            label.frame = NSRect(x: 0, y: (h - lh) / 2, width: bounds.width, height: lh)
        }
    }
}

final class ClosureMenuItem: NSMenuItem {
    private let block: () -> Void
    init(title: String, _ block: @escaping () -> Void) {
        self.block = block
        super.init(title: title, action: #selector(run), keyEquivalent: "")
        target = self
    }
    required init(coder: NSCoder) { fatalError() }
    @objc private func run() { block() }
}

enum Pasteboard {
    static func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

enum Alerts {
    static func info(_ title: String, _ text: String) {
        let a = NSAlert()
        a.messageText = title
        a.informativeText = text
        a.runModal()
    }
}

enum AppIconCache {
    private static var cache: [String: NSImage] = [:]
    private static let generic: NSImage = {
        let img = NSImage(systemSymbolName: "gearshape", accessibilityDescription: nil) ?? NSImage()
        img.isTemplate = true
        return img
    }()

    /// Icons are rasterised once at 32 px; resampling the full icon on every refresh was costly.
    static func icon(_ path: String?) -> NSImage {
        guard let path else { return generic }
        if let i = cache[path] { return i }
        let src = NSWorkspace.shared.icon(forFile: path)
        let out = NSImage(size: NSSize(width: 16, height: 16))
        if let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 32, pixelsHigh: 32, bitsPerSample: 8, samplesPerPixel: 4,
                                      hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) {
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            src.draw(in: NSRect(x: 0, y: 0, width: 32, height: 32))
            NSGraphicsContext.restoreGraphicsState()
            out.addRepresentation(rep)
        }
        cache[path] = out
        return out
    }
}
