import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct InspectorTarget: Codable, Hashable {
    var pid: Int32
    var sample: Bool
}

/// Per-process detail window, like Activity Monitor's “Inspect Process”.
struct ProcessInspector: View {
    let target: InspectorTarget
    @Environment(Monitor.self) private var monitor
    @State private var tab = 0
    @State private var files: [ProcessDetails.FD]?
    @State private var filesLoaded = false
    @State private var signing: ProcessDetails.Signing?
    @State private var sampleText = ""
    @State private var sampling = false
    @State private var confirmKill = false
    @State private var message: String?
    @State private var lastStat: ProcessStat?

    private var pid: pid_t { target.pid }

    var body: some View {
        let live = monitor.snapshot.processes.first { $0.pids.first == pid }
        let stat = live ?? lastStat
        VStack(alignment: .leading, spacing: 10) {
            if let stat {
                header(stat, alive: live != nil)
                Picker("", selection: $tab) {
                    Text("概览").tag(0)
                    Text("打开的文件和端口").tag(1)
                    Text("采样").tag(2)
                }
                .pickerStyle(.segmented).labelsHidden()
                switch tab {
                case 0: overview(stat)
                case 1: filesView(stat)
                default: sampleView(stat)
                }
            } else {
                ContentUnavailableView("进程 \(pid) 不存在", systemImage: "questionmark.app", description: Text("它可能已经退出。"))
            }
        }
        .padding(14)
        .frame(minWidth: 520, minHeight: 460)
        .onAppear {
            if target.sample { tab = 2; runSample() }
        }
        .onChange(of: live) { if let live { lastStat = live } }
        .task {
            if let s = live { lastStat = s }
            let path = live?.path ?? ""
            signing = await Task.detached { ProcessDetails.signing(path) }.value
        }
        .alert("强制退出 \(stat?.name ?? "")？", isPresented: $confirmKill) {
            Button("强制退出", role: .destructive) { ProcessActions.terminate([pid], force: true) }
            Button("取消", role: .cancel) {}
        } message: { Text("未保存的内容会丢失。") }
        .alert(message ?? "", isPresented: Binding(get: { message != nil }, set: { if !$0 { message = nil } })) {
            Button("好") { message = nil }
        }
    }

    // MARK: Header

    private func header(_ s: ProcessStat, alive: Bool) -> some View {
        HStack(alignment: .center, spacing: 10) {
            Image(nsImage: AppIconCache.icon(s.appPath)).resizable().frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(s.name).font(.title3.bold())
                Text("PID \(pid) · \(s.user)\(s.translated ? " · Intel（Rosetta）" : "")\(alive ? "" : " · 已退出")")
                    .font(.caption).foregroundStyle(alive ? Color.secondary : Color.red)
            }
            Spacer()
            Menu("发送信号") {
                ForEach(ProcessActions.signals, id: \.1) { title, sig in
                    Button(title) { message = ProcessActions.send(sig, to: [pid]).map { "无法发送信号：\($0)。其他用户的进程需要管理员权限。" } }
                }
            }
            .fixedSize()
            Button("退出") { ProcessActions.terminate([pid], force: false) }
            Button("强制退出…") { confirmKill = true }
        }
        .controlSize(.small)
        .disabled(!alive)
    }

    // MARK: Overview

    private func overview(_ s: ProcessStat) -> some View {
        let parent = monitor.snapshot.processes.first { $0.pids.first == s.ppid }
        var rows: [(String, String)] = [
            ("路径", s.path.isEmpty ? "—" : s.path),
            ("父进程", parent.map { "\($0.name)（\(s.ppid)）" } ?? (s.ppid == 1 ? "launchd（1）" : "\(s.ppid)")),
            ("用户", "\(s.user)（uid \(s.uid)）"),
            ("启动时间", s.startTime.map { "\(Fmt.startTime($0))，已运行 \(Fmt.duration(Date().timeIntervalSince($0)).split(separator: ".").first ?? "")" } ?? "—"),
            ("种类", s.translated ? "Intel（通过 Rosetta 运行）" : "Apple 芯片原生"),
            ("% CPU", String(format: "%.1f%%", s.cpu)),
            ("CPU 时间", Fmt.duration(s.cpuTime)),
            ("线程", s.threads >= 0 ? "\(s.threads)" : "—（无权读取）"),
            ("空闲唤醒", s.idleWakeups.map { String(format: "%.0f 次/秒", $0) } ?? "—（无权读取）"),
            ("% GPU / GPU 时间", "\(s.gpu.map { String(format: "%.1f%%", $0) } ?? "—") / \(s.gpuTime.map { Fmt.duration($0) } ?? "—")"),
            ("内存", ByteFormat.short(s.memory) + (s.isOwn ? "" : "（常驻）")),
            ("实际内存 / 峰值", "\(ByteFormat.short(s.resident)) / \(s.peakMemory.map { ByteFormat.short($0) } ?? "—")"),
            ("功耗", Fmt.procWatts(s) + (s.avgPowerW.map { String(format: "，平均 %.2f W", $0) } ?? "")),
            ("累计能耗", s.energyJ.map { Fmt.energy($0) } ?? "—"),
            ("磁盘", s.isOwn ? "读 \(ByteFormat.rate(s.diskReadBps))，写 \(ByteFormat.rate(s.diskWriteBps))；累计读 \(ByteFormat.short(s.diskRead ?? 0))，写 \(ByteFormat.short(s.diskWritten ?? 0))" : "—（无权读取）"),
            ("阻止睡眠", s.preventingSleep ? "是" : "否"),
            ("能效核限制", s.background ? "已限制（后台优先级）" : "无"),
        ]
        if let app = s.appPath, let bundle = Bundle(path: app) {
            rows.append(("应用", "\(bundle.bundleIdentifier ?? "—") \(bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "")"))
        }
        if let g = signing {
            let who = g.apple ? "Apple" : (g.team.map { "团队 \($0)" } ?? "无团队（ad-hoc 或未签名）")
            rows.append(("代码签名", "\(g.valid ? "有效" : "无效")，\(who)，\(g.identifier ?? "—")"))
            rows.append(("沙盒 / 强化运行时", "\(g.sandboxed ? "已沙盒" : "未沙盒") / \(g.hardenedRuntime ? "开启" : "关闭")"))
        }
        return ScrollView {
            Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 5) {
                ForEach(rows.indices, id: \.self) { i in
                    GridRow {
                        Text(rows[i].0).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
                        Text(rows[i].1).textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                    }
                    .font(.callout)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: Files

    private func filesView(_ s: ProcessStat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(files.map { "\($0.count) 项" } ?? "").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("刷新") { loadFiles() }.controlSize(.small)
            }
            if let files {
                List(files) { fd in
                    HStack(alignment: .firstTextBaseline) {
                        Text("\(fd.id)").monospacedDigit().foregroundStyle(.secondary).frame(width: 34, alignment: .trailing)
                        Text(fd.kind.rawValue).foregroundStyle(.secondary).frame(width: 64, alignment: .leading)
                        Text(fd.text).textSelection(.enabled).lineLimit(1).truncationMode(.middle)
                    }
                    .font(.caption)
                }
            } else if filesLoaded {
                ContentUnavailableView("无法读取", systemImage: "lock", description: Text("只能查看你自己的进程打开的文件和端口；系统和其他用户的进程需要管理员权限。"))
            } else {
                ProgressView()
            }
        }
        .onAppear { if !filesLoaded { loadFiles() } }
    }

    private func loadFiles() {
        let pid = self.pid
        Task {
            let result = await Task.detached { ProcessDetails.openFiles(pid) }.value
            files = result
            filesLoaded = true
        }
    }

    // MARK: Sample

    private func sampleView(_ s: ProcessStat) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button(sampling ? "采样中（3 秒）…" : "采样 3 秒") { runSample() }.disabled(sampling)
                Text("记录这几秒内各线程正在执行的函数调用栈，用来分析程序卡在哪里、忙什么。").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if !sampleText.isEmpty {
                    Button("拷贝") { Pasteboard.copy(sampleText) }
                    Button("存储…") { save() }
                }
            }
            .controlSize(.small)
            ScrollView([.vertical, .horizontal]) {
                Text(sampleText.isEmpty ? (sampling ? "" : "尚未采样") : sampleText)
                    .font(.system(size: 10.5, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .background(.background.secondary, in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func runSample() {
        guard !sampling else { return }
        sampling = true
        let pid = self.pid
        Task {
            sampleText = await Task.detached { ProcessDetails.sample(pid) }.value
            sampling = false
        }
    }

    private func save() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "Sample of \(lastStat?.name ?? "\(pid)").txt"
        panel.allowedContentTypes = [.plainText]
        if panel.runModal() == .OK, let url = panel.url {
            try? sampleText.write(to: url, atomically: true, encoding: .utf8)
        }
    }
}
