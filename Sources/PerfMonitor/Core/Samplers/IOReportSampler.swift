import CSensors
import Foundation
import IOKit

/// Power, frequency and GPU thermal-limit data from the private IOReport API.
/// Channel layout verified on A18 Pro; works the same on M-series.
final class IOReportSampler {
    struct Cluster {
        var active: Double = 0      // 0...1, share of time not idle
        var freqMHz: Double = 0     // average frequency while active
        var maxMHz: Double = 0
    }

    struct Result {
        var cpuW = 0.0, gpuW = 0.0, aneW = 0.0, dramW = 0.0
        /// Where cpuW came from: "clpc", "energy-model", or "" (unavailable; caller falls back).
        var cpuPowerSource = ""
        var dramAvailable = false
        var eCluster = Cluster(), pCluster = Cluster(), gpu = Cluster()
        var cores: [(name: String, active: Double, freqMHz: Double)] = []
        /// Share of GPU time spent under a thermal (CLTM) frequency cap.
        var gpuThermalLimited = 0.0
        /// Share of time the PMU reported lost GPU performance for thermal reasons.
        var gpuPerfLost = 0.0
    }

    private var channels: CFMutableDictionary?
    private var subscription: IOReportSubscriptionRef?
    private var previous: CFDictionary?
    private var previousTime = Date()
    private var sawCPUEnergy = false
    private var hasCLPC = false

    private let eFreqs: [Double]
    private let pFreqs: [Double]
    private let gpuFreqs: [Double]

    init() {
        eFreqs = Self.frequencyTable("voltage-states1-sram")
        pFreqs = Self.frequencyTable("voltage-states5-sram")
        gpuFreqs = Self.frequencyTable("voltage-states9").filter { $0 > 0 }

        let wanted: [(String, String?)] = [
            ("Energy Model", nil),
            ("CPU Stats", "CPU Core Performance States"),
            ("GPU Stats", "GPU Performance States"),
            ("GPU Stats", "CLTM-induced GPU Performance States"),
            ("GPU Stats", "PMU Loop Lost Performance Reason Code States"),
        ]
        var base: CFDictionary?
        for (group, sub) in wanted {
            guard let ch = IOReportCopyChannelsInGroup(group as CFString, sub as CFString?, 0, 0, 0)?.takeRetainedValue() else { continue }
            if let base { IOReportMergeChannels(base, ch, nil) } else { base = ch }
        }
        guard let base,
              let mutable = CFDictionaryCreateMutableCopy(kCFAllocatorDefault, CFDictionaryGetCount(base), base) else { return }
        // macOS 27 froze the mJ "Energy Model" CPU/ANE/DRAM counters; AppleCLPC still keeps nJ totals.
        let clpc = CLPC.channels()
        if !clpc.isEmpty {
            let dict = mutable as NSMutableDictionary
            let list = NSMutableArray(array: dict["IOReportChannels"] as? [Any] ?? [])
            list.addObjects(from: clpc)
            dict["IOReportChannels"] = list
            hasCLPC = true
        }
        channels = mutable
        var out: Unmanaged<CFMutableDictionary>?
        subscription = IOReportCreateSubscription(nil, channels, &out, 0, nil)
        out?.release()
    }

    func sample() -> Result? {
        guard let subscription, let channels,
              let current = IOReportCreateSamples(subscription, channels, nil)?.takeRetainedValue() else { return nil }
        let now = Date()
        defer { previous = current; previousTime = now }
        guard let previous,
              let delta = IOReportCreateSamplesDelta(previous, current, nil)?.takeRetainedValue() as? [String: Any],
              let items = delta["IOReportChannels"] as? [CFDictionary] else { return nil }
        let dt = max(now.timeIntervalSince(previousTime), 0.001)

        var r = Result()
        var clpcCPU: Double?, clpcANE: Double?
        var eCores: [(Double, Double, Double)] = [], pCores: [(Double, Double, Double)] = []

        for item in items {
            let group = IOReportChannelGetGroup(item)?.takeUnretainedValue() as String? ?? ""
            let name = IOReportChannelGetChannelName(item)?.takeUnretainedValue() as String? ?? ""

            if group == "CLPC" {
                let watts = Double(IOReportSimpleGetIntegerValue(item, 0)) / 1e9 / dt
                guard watts >= 0, watts < 500 else { continue }   // frozen counters can catch up in one jump
                if name == "CPU Energy" { clpcCPU = watts } else if name == "ANE" { clpcANE = watts }
                continue
            }

            if group == "Energy Model" {
                let unit = IOReportChannelGetUnitLabel(item)?.takeUnretainedValue() as String? ?? "mJ"
                let watts = Self.joules(Double(IOReportSimpleGetIntegerValue(item, 0)), unit: unit) / dt
                switch name {
                case "CPU Energy": r.cpuW = watts
                case "GPU Energy": r.gpuW = watts
                case "ANE": r.aneW = watts
                case "DRAM": r.dramW = watts
                default: break
                }
                continue
            }

            let states = Self.states(item)
            let sub = IOReportChannelGetSubGroup(item)?.takeUnretainedValue() as String? ?? ""
            switch sub {
            case "CPU Core Performance States":
                let isP = name.hasPrefix("PCPU")
                let (active, freq, total) = Self.residency(states, table: isP ? pFreqs : eFreqs)
                r.cores.append((name, active, freq))
                if isP { pCores.append((active, freq, total)) } else { eCores.append((active, freq, total)) }
            case "GPU Performance States":
                let (active, freq, _) = Self.residency(states, table: gpuFreqs)
                r.gpu = Cluster(active: active, freqMHz: freq, maxMHz: gpuFreqs.last ?? 0)
            case "CLTM-induced GPU Performance States":
                let total = states.reduce(0) { $0 + $1.1 }
                let free = states.first { $0.0 == "NO_CLTM" }?.1 ?? total
                r.gpuThermalLimited = total > 0 ? 1 - free / total : 0
            case "PMU Loop Lost Performance Reason Code States":
                let total = states.reduce(0) { $0 + $1.1 }
                let none = states.filter { $0.0 == "NONE" || $0.0 == "INVALID" }.reduce(0) { $0 + $1.1 }
                r.gpuPerfLost = total > 0 ? 1 - none / total : 0
            default: break
            }
        }

        if r.cpuW > 0 { sawCPUEnergy = true }
        r.dramAvailable = r.dramW > 0
        if let clpcCPU {
            r.cpuW = clpcCPU
            r.aneW = clpcANE ?? r.aneW
            r.cpuPowerSource = "clpc"
        } else if sawCPUEnergy {
            r.cpuPowerSource = "energy-model"
        }
        r.eCluster = Self.combine(eCores, max: eFreqs.last ?? 0)
        r.pCluster = Self.combine(pCores, max: pFreqs.last ?? 0)
        return r
    }

    var clpcAvailable: Bool { hasCLPC }
    var pCoreMaxMhz: Double? { pFreqs.last }
    var eCoreMaxMhz: Double? { eFreqs.last }
    var gpuMaxMhz: Double? { gpuFreqs.last }

    // MARK: - Helpers

    private static func states(_ item: CFDictionary) -> [(String, Double)] {
        let n = IOReportStateGetCount(item)
        guard n > 0 else { return [] }
        return (0..<n).map {
            (IOReportStateGetNameForIndex(item, $0)?.takeUnretainedValue() as String? ?? "",
             Double(IOReportStateGetResidency(item, $0)))
        }
    }

    /// Active share and residency-weighted frequency. Performance states are
    /// listed slowest first; when there are more states than table entries
    /// the extra low states share the slowest frequency.
    private static func residency(_ states: [(String, Double)], table: [Double]) -> (Double, Double, Double) {
        let idleNames: Set = ["IDLE", "OFF", "DOWN"]
        let total = states.reduce(0) { $0 + $1.1 }
        let perf = states.filter { !idleNames.contains($0.0) }
        let activeTime = perf.reduce(0) { $0 + $1.1 }
        guard total > 0, activeTime > 0, !table.isEmpty else { return (total > 0 ? activeTime / total : 0, 0, total) }
        let offset = perf.count - table.count
        var weighted = 0.0
        for (i, s) in perf.enumerated() {
            weighted += s.1 * table[min(max(i - offset, 0), table.count - 1)]
        }
        return (activeTime / total, weighted / activeTime, total)
    }

    private static func combine(_ cores: [(Double, Double, Double)], max: Double) -> Cluster {
        guard !cores.isEmpty else { return Cluster(maxMHz: max) }
        let active = cores.map(\.0).reduce(0, +) / Double(cores.count)
        let weight = cores.map(\.0).reduce(0, +)
        let freq = weight > 0 ? cores.map { $0.0 * $0.1 }.reduce(0, +) / weight : 0
        return Cluster(active: active, freqMHz: freq, maxMHz: max)
    }

    private static func joules(_ v: Double, unit: String) -> Double {
        switch unit {
        case "nJ": return v / 1e9
        case "uJ": return v / 1e6
        default: return v / 1e3
        }
    }

    /// Reads a DVFS table from the pmgr node: pairs of (freq, voltage) uint32.
    /// Older chips store Hz, newer ones kHz; result is MHz.
    private static func frequencyTable(_ key: String) -> [Double] {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var name = [CChar](repeating: 0, count: 128)
            IORegistryEntryGetName(entry, &name)
            guard String(cString: name) == "pmgr",
                  let data = IORegistryEntryCreateCFProperty(entry, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Data
            else { continue }
            var freqs: [Double] = []
            data.withUnsafeBytes { raw in
                for i in stride(from: 0, to: raw.count - 7, by: 8) {
                    freqs.append(Double(raw.loadUnaligned(fromByteOffset: i, as: UInt32.self)))
                }
            }
            let hz = (freqs.max() ?? 0) > 100_000_000
            return freqs.map { hz ? $0 / 1e6 : $0 / 1e3 }
        }
        return []
    }
}
