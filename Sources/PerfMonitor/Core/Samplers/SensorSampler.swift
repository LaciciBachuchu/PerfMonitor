import CSensors
import Foundation

/// Temperatures and board-level power from the SMC and HID sensors.
final class SensorSampler {
    struct Reading {
        var avg: Double
        var max: Double
    }

    struct Result {
        var soc: Reading?          // PMU die sensors (HID)
        var pCores: Reading?       // SMC Tp0*
        var eCores: Reading?       // SMC Te0*
        var gpu: Reading?          // SMC Tg0*
        var battery: Double?
        var ssd: Double?
        var systemW: Double?       // SMC PSTR: whole-system draw
        var adapterW: Double?      // SMC PDTR: DC-in power
        var fans: [Double] = []    // RPM, empty on fanless Macs
    }

    private var pKeys: [String] = []
    private var eKeys: [String] = []
    private var gKeys: [String] = []
    private var fanCount = 0
    private var tick = 0
    private var lastHID: [String: Double] = [:]

    init() {
        guard SMCOpen() else { return }
        var buf = [CChar](repeating: 0, count: 5)
        for i in 0..<SMCKeyCount() where SMCKeyAtIndex(i, &buf) {
            let key = String(cString: buf)
            // Tp0x/Te0x/Tg0x are per-sensor; Tpx*/Tex* are pre-aggregated duplicates.
            if key.hasPrefix("Tp0") { pKeys.append(key) }
            else if key.hasPrefix("Te0") { eKeys.append(key) }
            else if key.hasPrefix("Tg0") { gKeys.append(key) }
        }
        fanCount = Int(Self.smc("FNum") ?? 0)
    }

    func sample() -> Result {
        var r = Result()
        r.pCores = Self.reading(pKeys.compactMap(Self.smcTemp))
        r.eCores = Self.reading(eKeys.compactMap(Self.smcTemp))
        r.gpu = Self.reading(gKeys.compactMap(Self.smcTemp))
        r.systemW = Self.smc("PSTR")
        r.adapterW = Self.smc("PDTR").flatMap { $0 > 0.05 ? $0 : nil }
        r.battery = Self.smcTemp("TB0T")
        r.fans = (0..<fanCount).compactMap { Self.smc("F\($0)Ac") }

        // HID reads are the slowest sensor path; die temps move slowly enough to read every other tick.
        if tick % 2 == 0, let fresh = CSensorsCopyHIDTemperatures()?.takeRetainedValue() as? [String: Double] {
            lastHID = fresh
        }
        tick += 1
        if !lastHID.isEmpty {
            let hid = lastHID
            r.soc = Self.reading(hid.filter { $0.key.hasPrefix("PMU tdie") }.map(\.value))
            r.ssd = hid.first { $0.key.hasPrefix("NAND") }?.value
            if r.battery == nil { r.battery = hid["gas gauge battery"] }
            if r.pCores == nil, r.soc != nil { r.pCores = r.soc }
        }
        return r
    }

    private static func smc(_ key: String) -> Double? {
        var v = 0.0
        return SMCReadDouble(key, &v) ? v : nil
    }

    private static func smcTemp(_ key: String) -> Double? {
        guard let v = smc(key), v > 5, v < 130 else { return nil }
        return v
    }

    private static func reading(_ values: [Double]) -> Reading? {
        guard let max = values.max() else { return nil }
        return Reading(avg: values.reduce(0, +) / Double(values.count), max: max)
    }
}
