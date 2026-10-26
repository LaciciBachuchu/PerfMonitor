import Foundation

protocol DataSource: AnyObject {
    func currentSnapshot() -> Snapshot
    func currentSensors() -> [SensorReading]
    func currentHardware() -> HardwareInfo?
    /// nil when the app isn't running: saved sessions are read from disk, nothing can be started.
    var tracker: Tracker? { get }
    func startTracking(target: String, seconds: Double?, network: Bool) -> Result<TrackSession, Tracker.StartError>
}

extension Monitor: DataSource {
    var tracker: Tracker? { tracking }
}

/// Samples in-process when the app isn't running (CLI / MCP fallback).
final class LocalSource: DataSource {
    private let queue = DispatchQueue(label: "perfmonitor.local")
    private var engine: Engine?
    private var last: Snapshot?
    private var lastTime = Date.distantPast
    private var hw: HardwareInfo?

    func currentSnapshot() -> Snapshot {
        queue.sync {
            if engine == nil {
                engine = Engine()
                engine?.powerMode = PowerModeControl.read().current
                Thread.sleep(forTimeInterval: 1)    // deltas need a real interval
            }
            if let last, Date().timeIntervalSince(lastTime) < 1 { return last }
            let s = engine!.sample()
            last = s; lastTime = Date()
            return s
        }
    }

    func currentSensors() -> [SensorReading] { SensorCatalog().read() }

    var tracker: Tracker? { nil }
    func startTracking(target: String, seconds: Double?, network: Bool) -> Result<TrackSession, Tracker.StartError> {
        .failure(.notFound(target))
    }

    func currentHardware() -> HardwareInfo? {
        if let hw { return hw }
        let io = queue.sync { engine?.io }
        hw = HardwareInfo.gather(io: io ?? IOReportSampler())
        return hw
    }
}

enum APIRouter {
    static let port: UInt16 = 47823
    static let endpoints: [String: String] = [
        "/v1/status": "整体状态：一句话摘要、瓶颈诊断、CPU/GPU/温度/内存/功耗/电池、占用最高的进程。参数 top=N",
        "/v1/processes": "进程列表。参数 sort=cpu|power|memory|disk|gpu|threads，limit=N，group=app|process",
        "/v1/sensors": "全部温度/电源传感器（SMC + HID）",
        "/v1/hardware": "硬件信息：型号、芯片、核心、内存、存储、显示器、充电规格",
        "/v1/findings": "只返回瓶颈诊断",
        "/v1/tracks": "性能追踪记录列表（每条含汇总）",
        "/v1/tracks/{id}": "一条追踪记录的汇总与分进程明细。参数 samples=1 附带时间序列",
        "POST /v1/tracks/start": "开始追踪一个应用或进程。参数 target=名称|PID|.app 路径，minutes=N（到时自动停止，可省略），network=1",
        "POST /v1/tracks/{id}/stop": "停止追踪（id 也可以写应用名，停止该应用所有进行中的追踪）",
    ]

    /// Returns (HTTP status, JSON body).
    static func handle(method: String = "GET", path rawPath: String, source: DataSource) -> (Int, Data) {
        let comps = URLComponents(string: "http://x" + rawPath)
        let path = comps?.path ?? rawPath
        var q: [String: String] = [:]
        for item in comps?.queryItems ?? [] { q[item.name] = item.value ?? "" }

        if path.hasPrefix("/v1/tracks") { return tracks(method: method, path: path, query: q, source: source) }
        guard method == "GET" else { return (405, JSON.encode(["error": "only GET is supported here"])) }

        switch path {
        case "/", "/v1", "/v1/":
            return (200, JSON.encode(["service": AnyCodable("PerfMonitor"), "endpoints": AnyCodable(endpoints)]))
        case "/v1/status":
            return (200, JSON.encode(StatusReport(source.currentSnapshot(), topCount: Int(q["top"] ?? "") ?? 8)))
        case "/v1/processes":
            let procs = StatusReport.processes(source.currentSnapshot(), sort: q["sort"] ?? "cpu",
                                               limit: Int(q["limit"] ?? "") ?? 20, grouped: (q["group"] ?? "app") != "process")
            return (200, JSON.encode(procs))
        case "/v1/sensors":
            return (200, JSON.encode(source.currentSensors()))
        case "/v1/hardware":
            guard let hw = source.currentHardware() else { return (503, JSON.encode(["error": "hardware info not ready"])) }
            return (200, JSON.encode(hw))
        case "/v1/findings":
            return (200, JSON.encode(StatusReport(source.currentSnapshot(), topCount: 1).findings))
        default:
            return (404, JSON.encode(["error": "not found", "see": "/v1"]))
        }
    }
}

extension APIRouter {
    private static func error(_ status: Int, _ message: String) -> (Int, Data) {
        (status, JSON.encode(["error": message]))
    }

    private static func tracks(method: String, path: String, query q: [String: String], source: DataSource) -> (Int, Data) {
        let parts = path.split(separator: "/").map(String.init)   // ["v1", "tracks", id?, action?]
        let sessions = source.tracker?.all() ?? Tracker.loadAll()
        let samples = ["1", "true", "yes"].contains(q["samples"] ?? "")

        if method == "GET" {
            if parts.count == 2 { return (200, JSON.encode(sessions.map { TrackReport($0, includeSamples: false) })) }
            guard parts.count == 3, let s = sessions.first(where: { $0.id == parts[2] }) else { return error(404, "没有这条追踪记录") }
            return (200, JSON.encode(TrackReport(s, includeSamples: samples)))
        }
        guard method == "POST" else { return error(405, "use GET or POST") }
        guard let tracker = source.tracker else { return error(503, "PerfMonitor.app 没有运行，无法开始或停止追踪") }

        if parts.count == 3, parts[2] == "start" {
            guard let target = q["target"], !target.trimmingCharacters(in: .whitespaces).isEmpty else {
                return error(400, "缺少 target 参数（应用名、进程名、PID 或 .app 路径）")
            }
            let seconds = Double(q["minutes"] ?? "").map { $0 * 60 } ?? Double(q["seconds"] ?? "")
            let network = ["1", "true", "yes"].contains(q["network"] ?? "")
            switch source.startTracking(target: target, seconds: seconds, network: network) {
            case .success(let s): return (200, JSON.encode(TrackReport(s, includeSamples: false)))
            case .failure(let e): return error(400, e.description)
            }
        }
        if parts.count == 4, parts[3] == "stop" {
            let key = parts[2].removingPercentEncoding ?? parts[2]
            let ids = sessions.contains { $0.id == key } ? [key]
                : sessions.filter { $0.active && ($0.name.caseInsensitiveCompare(key) == .orderedSame || $0.target.caseInsensitiveCompare(key) == .orderedSame) }.map(\.id)
            guard !ids.isEmpty else { return error(404, "没有进行中的「\(key)」追踪") }
            let stopped = ids.compactMap { tracker.stop($0) }.map { TrackReport($0, includeSamples: samples) }
            return (200, stopped.count == 1 ? JSON.encode(stopped[0]) : JSON.encode(stopped))
        }
        return error(404, "not found")
    }
}

/// Minimal type-erased Encodable for small ad-hoc payloads.
struct AnyCodable: Encodable {
    private let encodeImpl: (Encoder) throws -> Void
    init<T: Encodable>(_ v: T) { encodeImpl = v.encode }
    func encode(to encoder: Encoder) throws { try encodeImpl(encoder) }
}
