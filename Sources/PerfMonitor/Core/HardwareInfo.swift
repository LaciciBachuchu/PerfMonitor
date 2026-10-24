import AppKit
import CSensors
import CoreGraphics
import Foundation
import IOKit

/// Static facts about this Mac. Gathered once (system_profiler takes ~0.7 s).
struct HardwareInfo: Codable {
    struct Display: Codable {
        var name: String
        var builtIn: Bool
        var current: String          // e.g. "1920×1080 @ 120 Hz"
        var maxResolution: String    // largest pixel mode the display offers
        var maxRefreshHz: Double?
    }

    struct Spec: Codable {
        var note: String
        var builtInDisplay: String?
        var externalDisplays: String?
        var charging: String?
    }

    var modelName = ""
    var modelID = ""
    var chip = ""
    var performanceCores = 0
    var efficiencyCores = 0
    var gpuCores: Int?
    var pCoreMaxMhz: Double?
    var eCoreMaxMhz: Double?
    var gpuMaxMhz: Double?
    var memoryGB = 0.0
    var memoryType: String?
    var memoryMaker: String?
    var storageModel: String?
    var storageBytes: Double?
    var storageFreeBytes: Double?
    var macosVersion = ""
    var displays: [Display] = []
    var fans = 0
    var officialSpec: Spec?

    /// Apple spec sheet facts that the hardware itself doesn't report.
    private static let specs: [String: Spec] = [
        "Mac17,5": Spec(
            note: "Apple 官方规格（apple.com/macbook-neo/specs）",
            builtInDisplay: "13.0 英寸 IPS，2408×1506，219 ppi，500 尼特",
            externalDisplays: "最多 1 台外接显示器，最高 4K @ 60 Hz",
            charging: "USB-C PD 充电，官方最低 20 W"
        ),
    ]

    static func gather(io: IOReportSampler? = nil) -> HardwareInfo {
        var h = HardwareInfo()
        h.modelID = sysctlString("hw.model") ?? ""
        h.chip = sysctlString("machdep.cpu.brand_string") ?? ""
        h.performanceCores = sysctlInt("hw.perflevel0.logicalcpu") ?? 0
        h.efficiencyCores = sysctlInt("hw.perflevel1.logicalcpu") ?? 0
        h.memoryGB = Double(sysctlInt("hw.memsize") ?? 0) / 1_073_741_824
        let v = ProcessInfo.processInfo.operatingSystemVersion
        h.macosVersion = "\(v.majorVersion).\(v.minorVersion).\(v.patchVersion)"
        h.officialSpec = specs[h.modelID]

        let gpu = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AGXAccelerator"))
        if gpu != 0 {
            h.gpuCores = (IORegistryEntryCreateCFProperty(gpu, "gpu-core-count" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? NSNumber)?.intValue
            IOObjectRelease(gpu)
        }
        if let io {
            h.pCoreMaxMhz = io.pCoreMaxMhz
            h.eCoreMaxMhz = io.eCoreMaxMhz
            h.gpuMaxMhz = io.gpuMaxMhz
        }

        if let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey]) {
            h.storageBytes = values.volumeTotalCapacity.map(Double.init)
            h.storageFreeBytes = values.volumeAvailableCapacityForImportantUsage.map(Double.init)
        }

        if let profile = systemProfiler(["SPHardwareDataType", "SPMemoryDataType", "SPNVMeDataType"]) {
            if let hw = (profile["SPHardwareDataType"] as? [[String: Any]])?.first {
                h.modelName = hw["machine_name"] as? String ?? ""
                if let chip = hw["chip_type"] as? String { h.chip = chip }
            }
            if let mem = (profile["SPMemoryDataType"] as? [[String: Any]])?.first {
                h.memoryType = mem["dimm_type"] as? String
                h.memoryMaker = mem["dimm_manufacturer"] as? String
            }
            if let nvme = ((profile["SPNVMeDataType"] as? [[String: Any]])?.first?["_items"] as? [[String: Any]])?.first {
                h.storageModel = nvme["device_model"] as? String
                if let b = nvme["size_in_bytes"] as? NSNumber { h.storageBytes = b.doubleValue }
            }
        }
        var fans = 0.0
        if SMCReadDouble("FNum", &fans) { h.fans = Int(fans) }
        // NSScreen must be touched on the main thread.
        h.displays = Thread.isMainThread ? displays() : DispatchQueue.main.sync { displays() }
        return h
    }

    private static func displays() -> [Display] {
        var count: UInt32 = 0
        CGGetOnlineDisplayList(0, nil, &count)
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        CGGetOnlineDisplayList(count, &ids, &count)
        let screens = NSScreen.screens
        return ids.map { id in
            let screen = screens.first { ($0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value == id }
            let opts = [kCGDisplayShowDuplicateLowResolutionModes: kCFBooleanTrue] as CFDictionary
            let modes = (CGDisplayCopyAllDisplayModes(id, opts) as? [CGDisplayMode]) ?? []
            let best = modes.max { $0.pixelWidth * $0.pixelHeight < $1.pixelWidth * $1.pixelHeight }
            var maxHz = modes.map(\.refreshRate).max() ?? 0
            if let fps = screen?.maximumFramesPerSecond, Double(fps) > maxHz { maxHz = Double(fps) }
            var current = "—"
            if let m = CGDisplayCopyDisplayMode(id) {
                let hz = m.refreshRate > 0 ? m.refreshRate : Double(screen?.maximumFramesPerSecond ?? 0)
                current = "\(m.pixelWidth)×\(m.pixelHeight)" + (hz > 0 ? String(format: " @ %.0f Hz", hz) : "")
            }
            return Display(
                name: screen?.localizedName ?? (CGDisplayIsBuiltin(id) != 0 ? "内建显示器" : "显示器 \(id)"),
                builtIn: CGDisplayIsBuiltin(id) != 0,
                current: current,
                maxResolution: best.map { "\($0.pixelWidth)×\($0.pixelHeight)" } ?? "—",
                maxRefreshHz: maxHz > 0 ? maxHz : nil
            )
        }
    }

    private static func systemProfiler(_ types: [String]) -> [String: Any]? {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/system_profiler")
        p.arguments = ["-json", "-detailLevel", "mini"] + types
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var v: Int64 = 0
        var size = MemoryLayout<Int64>.size
        guard sysctlbyname(name, &v, &size, nil, 0) == 0 else { return nil }
        return Int(v)
    }
}
