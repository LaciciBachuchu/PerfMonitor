import Foundation

protocol DataSource: AnyObject {
    func currentSnapshot() -> Snapshot
    func currentSensors() -> [SensorReading]
    func currentHardware() -> HardwareInfo?
}

extension Monitor: DataSource {}

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
    ]

    /// Returns (HTTP status, JSON body).
    static func handle(path rawPath: String, source: DataSource) -> (Int, Data) {
        let comps = URLComponents(string: "http://x" + rawPath)
        let path = comps?.path ?? rawPath
        var q: [String: String] = [:]
        for item in comps?.queryItems ?? [] { q[item.name] = item.value ?? "" }

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

/// Minimal type-erased Encodable for small ad-hoc payloads.
struct AnyCodable: Encodable {
    private let encodeImpl: (Encoder) throws -> Void
    init<T: Encodable>(_ v: T) { encodeImpl = v.encode }
    func encode(to encoder: Encoder) throws { try encodeImpl(encoder) }
}
