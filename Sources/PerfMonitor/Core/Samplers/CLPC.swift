import Foundation
import IOKit

/// AppleCLPC aggregate energy counters (nJ), which keep counting on macOS 27 where the
/// IOReport "Energy Model" CPU channels read 0. Report IDs and channel layout are from
/// vladkens/macmon src/clpc.rs and src/sources.rs (MIT, © 2024 vladkens).
enum CLPC {
    private static let keys: [String: (cpu: UInt32, gpu: UInt32, ane: UInt32)] = [
        "com.apple.driver.AppleT6000CLPCv3": (0x4747_9059, 0x4519_bf1e, 0x9aaa_17f8),
        "com.apple.driver.AppleT6002CLPC": (0xb501_816b, 0x9e2c_3e8b, 0x14d5_a574),
        "com.apple.driver.AppleT6020CLPC": (0xe301_cd75, 0x8f34_cc7a, 0x7415_fb0f),
        "com.apple.driver.AppleT6022CLPC": (0x76f5_fd21, 0x9062_4499, 0x3c09_7307),
        "com.apple.driver.AppleT6030CLPC": (0xbe03_a01a, 0x472d_6c9c, 0xb899_0c38),
        "com.apple.driver.AppleT6031CLPC": (0xd81e_0084, 0x1085_f98b, 0x313a_3be1),
        "com.apple.driver.AppleT6032CLPC": (0xf4a2_1308, 0x85e8_0513, 0x63dc_8e25),
        "com.apple.driver.AppleT6041CLPC": (0x263c_f1f0, 0x22e4_cf59, 0x7849_fb5c),
        "com.apple.driver.AppleT6050CLPC": (0xd3ab_60bb, 0x27cd_4ce5, 0x8c0f_1c59),
        "com.apple.driver.AppleT6050dCLPC": (0x18b3_010e, 0xedec_a11a, 0x188b_d883),
        "com.apple.driver.AppleT8103CLPCv3": (0x2cdd_31f2, 0x21be_cf42, 0x0667_fb81),
        "com.apple.driver.AppleT8112CLPC": (0xb543_5137, 0x638d_9d52, 0xea08_9c36),
        "com.apple.driver.AppleT8122CLPC": (0x54b5_1c99, 0xce2d_d9dc, 0x960a_fe2f),
        "com.apple.driver.AppleT8132CLPC": (0x4a85_4d94, 0x3b3e_3b79, 0x1ff4_a9ec),
        "com.apple.driver.AppleT8140CLPC": (0x9bf5_4436, 0xef70_589c, 0x569d_941b),   // A18 Pro (MacBook Neo)
        "com.apple.driver.AppleT8142CLPC": (0x4370_8744, 0x6a01_0933, 0xbc5e_fdf0),
        "com.apple.driver.AppleT8152CLPC": (0x485d_4bfc, 0x1178_4654, 0x9380_c6bb),
    ]
    // Table indices for macOS 27.0 / 27.0.1.
    private static let cpuIndex: UInt64 = 16, gpuIndex: UInt64 = 25, aneIndex: UInt64 = 24

    /// Channel descriptors to merge into an IOReport subscription; empty when unsupported.
    static func channels() -> [NSDictionary] {
        guard ProcessInfo.processInfo.operatingSystemVersion.majorVersion == 27 else { return [] }
        var out: [NSDictionary] = []
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleCLPC"), &iterator) == KERN_SUCCESS else { return [] }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var driver: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(entry, &driver) == KERN_SUCCESS,
                  let bundle = IORegistryEntryCreateCFProperty(entry, "CFBundleIdentifier" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String,
                  let k = keys[bundle] else { continue }
            out.append(channel(driver: driver, id: (cpuIndex << 32) | UInt64(k.cpu), name: "CPU Energy"))
            out.append(channel(driver: driver, id: (aneIndex << 32) | UInt64(k.ane), name: "ANE"))
        }
        return out
    }

    private static func channel(driver: UInt64, id: UInt64, name: String) -> NSDictionary {
        // IOReportTypes.h: simple integer, power category, one element; unit nJ.
        let type: Int64 = 1 | (2 << 16) | (1 << 32)
        let unit: Int64 = (3 << 56) | (118 << 32)
        return NSMutableDictionary(dictionary: [
            "DriverID": NSNumber(value: Int64(bitPattern: driver)),
            "DriverName": "AppleCLPC",
            "IOReportGroupName": "CLPC",
            "IOReportSubGroupName": "Energy Counters",
            "IOReportChannelInfo": ["IOReportChannelUnit": NSNumber(value: unit)],
            "LegendChannel": [NSNumber(value: Int64(bitPattern: id)), NSNumber(value: type), name],
        ])
    }
}
