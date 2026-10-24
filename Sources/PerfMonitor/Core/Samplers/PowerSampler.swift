import Foundation
import IOKit

/// Charging, adapter and USB-C power-out telemetry from AppleSmartBattery.
final class PowerSampler {
    struct Port: Codable {
        var index: Int
        var volts: Double
        var amps: Double
        var watts: Double
    }

    struct Adapter: Codable {
        var description: String
        var ratedW: Double          // what the Mac negotiated / the adapter reports
        var volts: Double
        var amps: Double
        var maxOfferedW: Double?    // highest PD profile the charger advertises
    }

    struct Result: Codable {
        var hasBattery = false
        var percent: Double = 0
        var charging = false
        var onAC = false
        var fullyCharged = false
        /// + into the battery, − out of it.
        var batteryW: Double = 0
        /// Power entering the Mac from the USB-C input.
        var systemInW: Double?
        /// What the system is drawing in total (from battery and/or adapter).
        var systemLoadW: Double?
        var adapter: Adapter?
        /// Power the Mac is supplying to devices on its own ports.
        var portsOut: [Port] = []
        var health: Double?
        var cycles: Int?
        var designCapacityMAh: Int?
        var minutesToFull: Int?
        var minutesToEmpty: Int?
        var notChargingReason: Int?
        var thermallyLimitedChargeSeconds: Int?

        var portsOutW: Double { portsOut.reduce(0) { $0 + $1.watts } }
    }

    private var service: io_service_t = 0

    init() {
        service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    }

    deinit { if service != 0 { IOObjectRelease(service) } }

    func sample() -> Result {
        var r = Result()
        guard service != 0 else { return r }
        func prop(_ key: String) -> Any? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
        }
        func num(_ v: Any?) -> Double? { (v as? NSNumber)?.doubleValue }

        guard let cur = num(prop("CurrentCapacity")), let maxCap = num(prop("MaxCapacity")), maxCap > 0 else { return r }
        r.hasBattery = true
        r.percent = cur / maxCap
        r.charging = prop("IsCharging") as? Bool ?? false
        r.onAC = prop("ExternalConnected") as? Bool ?? false
        r.fullyCharged = prop("FullyCharged") as? Bool ?? false
        r.cycles = (prop("CycleCount") as? NSNumber)?.intValue

        let volts = (num(prop("Voltage")) ?? 0) / 1000
        let amps = Double(Int16(truncatingIfNeeded: (prop("InstantAmperage") as? NSNumber)?.intValue ?? 0)) / 1000
        r.batteryW = volts * amps

        if let t = prop("PowerTelemetryData") as? [String: Any] {
            r.systemInW = num(t["SystemPowerIn"]).map { $0 / 1000 }
            r.systemLoadW = num(t["SystemLoad"]).map { $0 / 1000 }
        }
        if !r.onAC { r.systemInW = 0 }

        if r.onAC, let a = prop("AdapterDetails") as? [String: Any] {
            let menu = (a["UsbHvcMenu"] as? [[String: Any]]) ?? []
            let offered = menu.compactMap { m -> Double? in
                guard let v = num(m["MaxVoltage"]), let i = num(m["MaxCurrent"]), v < 65535, i < 65535 else { return nil }
                return v * i / 1e6
            }.max()
            r.adapter = Adapter(
                description: a["Description"] as? String ?? "",
                ratedW: num(a["Watts"]) ?? 0,
                volts: (num(a["AdapterVoltage"]) ?? 0) / 1000,
                amps: (num(a["Current"]) ?? 0) / 1000,
                maxOfferedW: offered
            )
        }

        if let outs = prop("PowerOutDetails") as? [[String: Any]] {
            r.portsOut = outs.compactMap { o in
                let w = (num(o["Watts"]) ?? 0) / 1000
                guard w > 0.05 else { return nil }
                return Port(index: (o["PortIndex"] as? NSNumber)?.intValue ?? 0,
                            volts: (num(o["AdapterVoltage"]) ?? 0) / 1000,
                            amps: (num(o["Current"]) ?? 0) / 1000,
                            watts: w)
            }
        }

        // Newer Macs keep capacities inside BatteryData; Nominal/Design matches System Settings.
        let data = prop("BatteryData") as? [String: Any]
        let design = num(prop("DesignCapacity")) ?? num(data?["DesignCapacity"])
        let nominal = num(prop("AppleRawMaxCapacity")) ?? num(data?["NominalChargeCapacity"])
        if let design, let nominal, design > 0 { r.health = min(nominal / design, 1) }
        r.designCapacityMAh = design.map { Int($0) }

        if let m = (prop("AvgTimeToFull") as? NSNumber)?.intValue, m > 0, m < 65535 { r.minutesToFull = m }
        if let m = (prop("AvgTimeToEmpty") as? NSNumber)?.intValue, m > 0, m < 65535 { r.minutesToEmpty = m }
        if let c = prop("ChargerData") as? [String: Any] {
            r.notChargingReason = (c["NotChargingReason"] as? NSNumber)?.intValue
            r.thermallyLimitedChargeSeconds = (c["TimeChargingThermallyLimited"] as? NSNumber)?.intValue
        }
        return r
    }
}
