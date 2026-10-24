import Foundation

/// `perfmon <command>`: same binary as the app, dispatched in main.swift when run with arguments.
enum CLI {
    static let usage = """
    perfmon — PerfMonitor 命令行 / MCP 接口

    用法:
      perfmon status [--json] [--top N]        当前整体状态与瓶颈诊断
      perfmon processes [--sort cpu|power|memory|disk] [--limit N] [--per-process] [--json]
      perfmon sensors [--json]                 全部温度/电源传感器
      perfmon hardware [--json]                硬件信息
      perfmon watch [--interval 2]             持续刷新状态
      perfmon mcp                              以 MCP 服务器（stdio）运行，供 Claude Code 等 agent 调用
      perfmon api                              显示 HTTP API 地址与端点

    PerfMonitor.app 在运行时，数据直接取自它的本地 API（http://127.0.0.1:\(APIRouter.port)）；
    否则本进程自行采样（约需 1 秒）。
    """

    static func run(_ args: [String]) -> Int32 {
        let cmd = args.first ?? "help"
        let rest = Array(args.dropFirst())
        let json = rest.contains("--json")
        func opt(_ name: String) -> String? {
            guard let i = rest.firstIndex(of: name), i + 1 < rest.count else { return nil }
            return rest[i + 1]
        }

        switch cmd {
        case "status":
            let path = "/v1/status?top=\(opt("--top") ?? "8")"
            guard let data = Fetcher.get(path) else { return fail() }
            if json { print(String(decoding: data, as: UTF8.self)); return 0 }
            guard let r = decode(StatusReport.self, data) else { return fail() }
            printStatus(r)
        case "processes", "ps", "top":
            let group = rest.contains("--per-process") ? "process" : "app"
            let path = "/v1/processes?sort=\(opt("--sort") ?? "cpu")&limit=\(opt("--limit") ?? "15")&group=\(group)"
            guard let data = Fetcher.get(path) else { return fail() }
            if json { print(String(decoding: data, as: UTF8.self)); return 0 }
            guard let list = decode([StatusReport.Proc].self, data) else { return fail() }
            printProcesses(list)
        case "sensors":
            guard let data = Fetcher.get("/v1/sensors") else { return fail() }
            if json { print(String(decoding: data, as: UTF8.self)); return 0 }
            guard let list = decode([SensorReading].self, data) else { return fail() }
            var group = ""
            for r in list {
                if r.group != group { group = r.group; print("\n[\(group)]") }
                print("  " + pad(r.label + (r.inferred ? "*" : ""), 28) + lpad(String(format: "%.2f %@", r.value, r.unit), 12) + "   (\(r.source) \(r.key))")
            }
        case "hardware", "hw":
            guard let data = Fetcher.get("/v1/hardware") else { return fail() }
            print(String(decoding: data, as: UTF8.self))
        case "watch":
            let interval = Double(opt("--interval") ?? "2") ?? 2
            while true {
                guard let data = Fetcher.get("/v1/status?top=5"), let r = decode(StatusReport.self, data) else { return fail() }
                print("\u{1B}[2J\u{1B}[H", terminator: "")
                printStatus(r)
                Thread.sleep(forTimeInterval: interval)
            }
        case "mcp":
            MCPServer.run()
        case "api":
            print("http://127.0.0.1:\(APIRouter.port)  （仅本机可访问，只读）")
            for (k, v) in APIRouter.endpoints.sorted(by: { $0.key < $1.key }) { print("  GET \(k)\n      \(v)") }
            print(Fetcher.appRunning() ? "\nPerfMonitor.app 正在运行，API 可用。" : "\nPerfMonitor.app 未运行：HTTP API 不可用，但 CLI/MCP 仍可自行采样。")
        default:
            print(usage)
            return cmd == "help" || cmd == "--help" || cmd == "-h" ? 0 : 2
        }
        return 0
    }

    private static func fail() -> Int32 {
        FileHandle.standardError.write(Data("perfmon: 无法获取数据\n".utf8))
        return 1
    }

    static func decode<T: Decodable>(_ t: T.Type, _ data: Data) -> T? {
        let d = JSONDecoder()
        d.keyDecodingStrategy = .convertFromSnakeCase
        d.dateDecodingStrategy = .iso8601
        return try? d.decode(t, from: data)
    }

    private static func printStatus(_ r: StatusReport) {
        print("● \(r.summary)")
        print("  健康: \(r.health)    性能档位: \(r.powerMode)")
        for f in r.findings where f.kind != "idle" {
            print("  [\(f.severity)] \(f.title)\n      \(f.detail)\n      建议: \(f.advice)")
        }
        let c = r.cpu, g = r.gpu, t = r.thermal, m = r.memory, p = r.power
        print(String(format: "\nCPU   %5.1f%%  P核 %4.0f/%4.0f MHz (%3.0f%%)  E核 %4.0f MHz (%3.0f%%)  %.2f W [%@]",
                     c.usagePct, c.performanceCores.freqMhz, c.performanceCores.maxMhz, c.performanceCores.usagePct,
                     c.efficiencyCores.freqMhz, c.efficiencyCores.usagePct, c.powerW, c.powerSource))
        print(String(format: "GPU   %5.1f%%  %4.0f MHz  %.2f W  热限频 %.0f%%", g.usagePct, g.freqMhz, g.powerW, g.thermalLimitedPct))
        print("温度  SoC \(fmt(t.socC))  P核 \(fmt(t.pCoresC)) (热点 \(fmt(t.pCoresMaxC)))  E核 \(fmt(t.eCoresC))  GPU \(fmt(t.gpuC))  电池 \(fmt(t.batteryC))  SSD \(fmt(t.ssdC))  热压力 \(t.pressureLabel)")
        print(String(format: "内存  %@ / %@  压力 %@  swap %@  换入/出 %.0f/%.0f 页/s",
                     ByteFormat.short(m.usedBytes), ByteFormat.short(m.totalBytes), m.pressure, ByteFormat.short(m.swapUsedBytes),
                     m.swapInsPerSec, m.swapOutsPerSec))
        var pw = String(format: "功耗  整机 %.1f W  CPU %.2f  GPU %.2f  ANE %.2f", p.systemW, p.cpuW, p.gpuW, p.aneW)
        if let i = p.usbcInputW { pw += String(format: "  USB-C 输入 %.1f W", i) }
        pw += String(format: "  电池 %+.1f W  接口对外 %.1f W", p.batteryW, p.portsOutW)
        print(pw)
        print("\n进程（按应用合并，按 CPU 排序）")
        printProcesses(r.topProcesses)
    }

    private static func printProcesses(_ list: [StatusReport.Proc]) {
        print("  " + pad("名称", 30) + lpad("CPU", 8) + lpad("功耗", 10) + lpad("内存", 10))
        for p in list {
            let w = p.powerW.map { (p.powerEstimated ? "≈" : "") + String(format: "%.2fW", $0) } ?? "—"
            print("  " + pad(p.name, 30) + lpad(String(format: "%.1f%%", p.cpuPct), 8) + lpad(w, 10) + lpad(ByteFormat.short(p.memoryBytes), 10))
        }
    }

    /// Terminal column width: CJK and other wide characters take two cells.
    private static func width(_ s: String) -> Int {
        s.unicodeScalars.reduce(0) { $0 + ($1.properties.isEmojiPresentation || (0x1100...0x115F).contains($1.value) || (0x2E80...0xA4CF).contains($1.value) || (0xAC00...0xD7A3).contains($1.value) || (0xF900...0xFAFF).contains($1.value) || (0xFF00...0xFF60).contains($1.value) ? 2 : 1) }
    }

    private static func pad(_ s: String, _ n: Int) -> String {
        var t = s
        while width(t) > n - 1 { t.removeLast() }
        return t + String(repeating: " ", count: n - width(t))
    }

    private static func lpad(_ s: String, _ n: Int) -> String {
        String(repeating: " ", count: max(0, n - width(s))) + s
    }

    private static func fmt(_ c: Double?) -> String { c.map { String(format: "%.0f°C", $0) } ?? "—" }
}

/// Fetches an API path from the running app, falling back to in-process sampling.
enum Fetcher {
    private static let local = LocalSource()

    static func appRunning() -> Bool { remote("/v1", timeout: 0.5) != nil }

    static func get(_ path: String) -> Data? {
        if let d = remote(path, timeout: 8) { return d }
        let (status, body) = APIRouter.handle(path: path, source: local)
        return status == 200 ? body : nil
    }

    private static func remote(_ path: String, timeout: TimeInterval) -> Data? {
        guard let url = URL(string: "http://127.0.0.1:\(APIRouter.port)\(path)") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = timeout
        let sem = DispatchSemaphore(value: 0)
        var result: Data?
        URLSession.shared.dataTask(with: req) { data, resp, _ in
            if (resp as? HTTPURLResponse)?.statusCode == 200 { result = data }
            sem.signal()
        }.resume()
        sem.wait()
        return result
    }
}
