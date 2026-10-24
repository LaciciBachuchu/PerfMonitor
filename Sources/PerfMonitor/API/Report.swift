import Foundation

/// JSON shape served by the HTTP API, the CLI (`--json`) and the MCP tools.
/// Keys are snake_case; units are in the key name (_pct, _w, _c, _mhz, _bytes, _bps).
struct StatusReport: Codable {
    struct FindingOut: Codable { var severity: String; var kind: String; var title: String; var detail: String; var advice: String }
    struct Cluster: Codable { var usagePct: Double; var freqMhz: Double; var maxMhz: Double }
    struct CPU: Codable {
        var usagePct: Double
        var performanceCores: Cluster
        var efficiencyCores: Cluster
        var powerW: Double
        var powerSource: String
    }
    struct GPU: Codable { var usagePct: Double; var freqMhz: Double; var maxMhz: Double; var powerW: Double; var thermalLimitedPct: Double }
    struct Thermal: Codable {
        var pressure: String            // nominal | moderate | heavy | trapping | sleeping
        var pressureLabel: String
        var socC: Double?, socMaxC: Double?
        var pCoresC: Double?, pCoresMaxC: Double?
        var eCoresC: Double?, gpuC: Double?
        var batteryC: Double?, ssdC: Double?
        var fanless: Bool
        var fanRpm: [Double]
    }
    struct Memory: Codable {
        var usedBytes: Double, totalBytes: Double
        var pressure: String            // normal | warning | critical
        var swapUsedBytes: Double
        var swapInsPerSec: Double, swapOutsPerSec: Double
        var compressedBytes: Double
    }
    struct Power: Codable {
        var systemW: Double
        var cpuW: Double, gpuW: Double, aneW: Double
        var usbcInputW: Double?
        var batteryW: Double            // + charging, − discharging
        var portsOutW: Double
        var portsOut: [PowerSampler.Port]
        var adapter: PowerSampler.Adapter?
    }
    struct Battery: Codable {
        var percent: Double, charging: Bool, onAc: Bool
        var healthPct: Double?, cycles: Int?
        var minutesToFull: Int?, minutesToEmpty: Int?
    }
    struct Proc: Codable {
        var name: String
        var pids: [Int32]
        var cpuPct: Double
        var powerW: Double?
        var powerEstimated: Bool
        var memoryBytes: Double
        var diskBps: Double
    }

    var generatedAt: Date
    var summary: String
    var health: String                  // ok | warning | critical
    var findings: [FindingOut]
    var powerMode: String
    var cpu: CPU
    var gpu: GPU
    var thermal: Thermal
    var memory: Memory
    var power: Power
    var battery: Battery?
    var disk: [String: Double]
    var topProcesses: [Proc]

    init(_ s: Snapshot, topCount: Int = 8) {
        generatedAt = s.time
        findings = s.findings.map {
            FindingOut(severity: ["info", "warning", "critical"][$0.severity.rawValue], kind: $0.kind.rawValue,
                       title: $0.title, detail: $0.detail, advice: $0.advice)
        }
        let worst = s.findings.map(\.severity).max() ?? .info
        health = s.findings.contains(where: { $0.kind != .idle }) ? (worst == .critical ? "critical" : (worst == .warning ? "warning" : "ok")) : "ok"
        powerMode = ["automatic", "low", "high"][s.powerMode.rawValue]

        cpu = CPU(
            usagePct: s.system.cpuTotal * 100,
            performanceCores: Cluster(usagePct: s.io.pCluster.active * 100, freqMhz: s.io.pCluster.freqMHz, maxMhz: s.io.pCluster.maxMHz),
            efficiencyCores: Cluster(usagePct: s.io.eCluster.active * 100, freqMhz: s.io.eCluster.freqMHz, maxMhz: s.io.eCluster.maxMHz),
            powerW: s.io.cpuW, powerSource: s.io.cpuPowerSource
        )
        gpu = GPU(usagePct: s.gpuUtil * 100, freqMhz: s.io.gpu.freqMHz, maxMhz: s.io.gpu.maxMHz, powerW: s.io.gpuW,
                  thermalLimitedPct: max(s.io.gpuThermalLimited, s.io.gpuPerfLost) * 100)
        let pressureNames = ["nominal", "moderate", "heavy", "trapping", "sleeping"]
        thermal = Thermal(
            pressure: pressureNames[s.system.thermal.rawValue], pressureLabel: s.system.thermal.label,
            socC: s.sensors.soc?.avg, socMaxC: s.sensors.soc?.max,
            pCoresC: s.sensors.pCores?.avg, pCoresMaxC: s.sensors.pCores?.max,
            eCoresC: s.sensors.eCores?.avg, gpuC: s.sensors.gpu?.avg,
            batteryC: s.sensors.battery, ssdC: s.sensors.ssd,
            fanless: s.sensors.fans.isEmpty, fanRpm: s.sensors.fans
        )
        let m = s.system.memory
        memory = Memory(usedBytes: m.used, totalBytes: m.total,
                        pressure: m.pressureLevel >= 4 ? "critical" : (m.pressureLevel >= 2 ? "warning" : "normal"),
                        swapUsedBytes: m.swapUsed, swapInsPerSec: m.swapInsPerSec, swapOutsPerSec: m.swapOutsPerSec,
                        compressedBytes: m.compressed)
        power = Power(systemW: s.totalW, cpuW: s.io.cpuW, gpuW: s.io.gpuW, aneW: s.io.aneW,
                      usbcInputW: s.power.onAC ? s.power.systemInW : nil, batteryW: s.power.batteryW,
                      portsOutW: s.power.portsOutW, portsOut: s.power.portsOut, adapter: s.power.adapter)
        battery = s.power.hasBattery ? Battery(
            percent: s.power.percent * 100, charging: s.power.batteryW > 0.05, onAc: s.power.onAC,
            healthPct: s.power.health.map { $0 * 100 }, cycles: s.power.cycles,
            minutesToFull: s.power.minutesToFull, minutesToEmpty: s.power.minutesToEmpty) : nil
        disk = ["read_bps": s.system.diskReadBps, "write_bps": s.system.diskWriteBps]
        topProcesses = Self.processes(s, sort: "cpu", limit: topCount, grouped: true)

        var parts = [String(format: "CPU %.0f%%", cpu.usagePct), String(format: "GPU %.0f%%", gpu.usagePct)]
        if let t = thermal.socC { parts.append(String(format: "SoC %.0f°C", t)) }
        parts.append("热压力\(thermal.pressureLabel)")
        parts.append(String(format: "整机 %.1fW", power.systemW))
        parts.append("内存压力" + ["normal": "正常", "warning": "警告", "critical": "严重"][memory.pressure]!)
        let headline = s.findings.first.map { $0.kind == .idle ? "没有明显瓶颈" : $0.title } ?? "—"
        summary = headline + "。" + parts.joined(separator: "，")
    }

    static func processes(_ s: Snapshot, sort: String, limit: Int, grouped: Bool) -> [Proc] {
        let list = grouped ? s.apps : s.processes
        let key: (ProcessStat) -> Double = switch sort {
        case "power": { $0.powerW ?? 0 }
        case "memory": { $0.memory }
        case "disk": { $0.diskBps }
        default: { $0.cpu }
        }
        return list.sorted { key($0) > key($1) }.prefix(max(1, limit)).map {
            Proc(name: $0.name, pids: $0.pids, cpuPct: $0.cpu, powerW: $0.powerW, powerEstimated: $0.powerEstimated,
                 memoryBytes: $0.memory, diskBps: $0.diskBps)
        }
    }
}

enum JSON {
    static func encode<T: Encodable>(_ v: T, pretty: Bool = true) -> Data {
        let e = JSONEncoder()
        e.keyEncodingStrategy = .convertToSnakeCase
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = pretty ? [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes] : [.sortedKeys]
        e.nonConformingFloatEncodingStrategy = .convertToString(positiveInfinity: "inf", negativeInfinity: "-inf", nan: "nan")
        return (try? e.encode(v)) ?? Data("{}".utf8)
    }

    static func string<T: Encodable>(_ v: T, pretty: Bool = true) -> String {
        String(decoding: encode(v, pretty: pretty), as: UTF8.self)
    }
}
