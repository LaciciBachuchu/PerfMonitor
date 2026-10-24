import CSensors
import Foundation

struct SensorReading: Codable, Identifiable {
    var id: String { source + ":" + key }
    var key: String
    var source: String      // "SMC" or "HID"
    var group: String       // 中文分类
    var label: String
    var value: Double
    var unit: String        // "°C", "W", "V", "A"
    var inferred: Bool      // label is a best guess, not documented or cross-checked
}

/// Every temperature (and the known power keys) this Mac exposes. Read on demand only:
/// scanning ~100 SMC keys plus all HID sensors costs more than the regular sampler.
final class SensorCatalog {
    private var smcKeys: [String] = []

    init() {
        guard SMCOpen() else { return }
        var buf = [CChar](repeating: 0, count: 5)
        for i in 0..<SMCKeyCount() where SMCKeyAtIndex(i, &buf) {
            let k = String(cString: buf)
            if k.hasPrefix("T") || ["PSTR", "PDTR", "PBat", "VBat", "IBat", "VD0R", "ID0R"].contains(k) { smcKeys.append(k) }
        }
    }

    func read() -> [SensorReading] {
        var out: [SensorReading] = []
        for k in smcKeys {
            var v = 0.0
            guard SMCReadDouble(k, &v) else { continue }
            if k.hasPrefix("T") {
                guard v > 10, v < 130 else { continue }
                let (group, label, inferred) = Self.describe(k)
                out.append(SensorReading(key: k, source: "SMC", group: group, label: label, value: v, unit: "°C", inferred: inferred))
            } else {
                let (label, unit) = Self.electrical[k] ?? (k, "")
                out.append(SensorReading(key: k, source: "SMC", group: "电源", label: label, value: v, unit: unit, inferred: false))
            }
        }
        if let hid = CSensorsCopyAllHIDTemperatures()?.takeRetainedValue() as? [String: Double] {
            for (name, v) in hid {
                let (group, label) = Self.describeHID(name)
                out.append(SensorReading(key: name, source: "HID", group: group, label: label, value: v, unit: "°C", inferred: false))
            }
        }
        return out.sorted { ($0.group, $0.key) < ($1.group, $1.key) }
    }

    private static let electrical: [String: (String, String)] = [
        "PSTR": ("整机功耗", "W"), "PDTR": ("USB-C 输入功率", "W"), "PBat": ("电池功率", "W"),
        "VBat": ("电池电压", "V"), "IBat": ("电池电流", "A"), "VD0R": ("USB-C 输入电压", "V"), "ID0R": ("USB-C 输入电流", "A"),
    ]

    private static func describe(_ k: String) -> (String, String, Bool) {
        let p2 = String(k.prefix(2)), p3 = String(k.prefix(3))
        switch true {
        case p3 == "Tp0": return ("CPU 性能核", "P 核区域 \(k)", false)
        case p3 == "Tpx": return ("CPU 性能核", "P 核汇总 \(k)", false)
        case p3 == "Te0", p3 == "Tex": return ("CPU 能效核", "E 核区域 \(k)", false)
        case p3 == "Tg0": return ("GPU", "GPU 区域 \(k)", false)
        case p2 == "Ts": return ("SoC", "SoC 其他区域 \(k)", true)
        case p3 == "TPD": return ("电源管理芯片", "PMU 芯片 \(k)", false)
        case p2 == "TR": return ("电源管理芯片", "PMU2 \(k)", false)
        case p2 == "TB", p3 == "TG0": return ("电池", "电池 \(k)", k != "TB0T")
        case p2 == "TH": return ("存储", "SSD \(k)", false)
        case p2 == "TQ": return ("充电", "充电芯片 \(k)", false)
        case p2 == "TW": return ("无线", "Wi-Fi/蓝牙模块 \(k)", true)
        case p3 == "TS0", p3 == "TS1": return ("机身", "机身表面 \(k)", true)
        case p2 == "Ta": return ("机身", "机内空气 \(k)", true)
        default: return ("其他", k, true)
        }
    }

    private static func describeHID(_ name: String) -> (String, String) {
        if name.hasPrefix("PMU tdie") { return ("SoC", "SoC 核心 " + name.dropFirst(8)) }
        if name.hasPrefix("PMU tdev") { return ("电源管理芯片", "PMU 器件 " + name.dropFirst(8)) }
        if name.hasPrefix("PMU2") || name.hasPrefix("PMU tcal") { return ("电源管理芯片", name) }
        if name.hasPrefix("NAND") { return ("存储", "SSD 闪存 " + name) }
        if name.hasPrefix("Charger") { return ("充电", "充电芯片 " + name.dropFirst(8)) }
        if name.hasPrefix("gas gauge") { return ("电池", "电池（电量计）") }
        return ("其他", name)
    }
}
