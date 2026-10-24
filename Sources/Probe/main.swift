// Dumps what this Mac exposes: IOReport channels, SMC keys, HID temps.
import CSensors
import Foundation

func channels(_ group: String) {
    guard let ch = IOReportCopyChannelsInGroup(group as CFString, nil, 0, 0, 0)?.takeRetainedValue(),
          let dict = ch as? [String: Any], let list = dict["IOReportChannels"] as? [CFDictionary] else {
        print("[\(group)] none"); return
    }
    print("[\(group)] \(list.count) channels")
    for item in list {
        let sub = IOReportChannelGetSubGroup(item)?.takeUnretainedValue() as String? ?? "-"
        let name = IOReportChannelGetChannelName(item)?.takeUnretainedValue() as String? ?? "-"
        let unit = IOReportChannelGetUnitLabel(item)?.takeUnretainedValue() as String? ?? ""
        print("   \(sub) | \(name) | \(unit)")
    }
}

for g in ["Energy Model", "CPU Stats", "GPU Stats", "PMP"] { channels(g) }

print("\n[HID temps]")
if let t = CSensorsCopyHIDTemperatures()?.takeRetainedValue() as? [String: Double] {
    for (k, v) in t.sorted(by: { $0.key < $1.key }) { print(String(format: "   %@ = %.1f", k, v)) }
}

print("\n[SMC] keys:", SMCKeyCount())
var key = [CChar](repeating: 0, count: 5)
for i in 0..<SMCKeyCount() {
    guard SMCKeyAtIndex(i, &key) else { continue }
    let k = String(cString: key)
    guard let f = k.first, "TPFVI".contains(f) else { continue }
    var v = 0.0
    if SMCReadDouble(k, &v), v != 0 { print(String(format: "   %@ = %.2f", k, v)) }
}

print("\n[State residency over 1s]")
func merged(_ groups: [String]) -> CFMutableDictionary? {
    var base: CFDictionary?
    for g in groups {
        guard let c = IOReportCopyChannelsInGroup(g as CFString, nil, 0, 0, 0)?.takeRetainedValue() else { continue }
        if let b = base { IOReportMergeChannels(b, c, nil) } else { base = c }
    }
    guard let b = base else { return nil }
    return CFDictionaryCreateMutableCopy(kCFAllocatorDefault, CFDictionaryGetCount(b), b)
}
if let chans = merged(["CPU Stats", "GPU Stats"]) {
    var out: Unmanaged<CFMutableDictionary>?
    let sub = IOReportCreateSubscription(nil, chans, &out, 0, nil)
    let s1 = IOReportCreateSamples(sub, chans, nil)!.takeRetainedValue()
    Thread.sleep(forTimeInterval: 1)
    let s2 = IOReportCreateSamples(sub, chans, nil)!.takeRetainedValue()
    let d = IOReportCreateSamplesDelta(s1, s2, nil)!.takeRetainedValue() as! [String: Any]
    for item in d["IOReportChannels"] as! [CFDictionary] {
        let sub = IOReportChannelGetSubGroup(item)?.takeUnretainedValue() as String? ?? ""
        let name = IOReportChannelGetChannelName(item)?.takeUnretainedValue() as String? ?? ""
        guard ["CPU Core Performance States", "CPU Complex Performance States", "GPU Performance States", "CLTM-induced GPU Performance States", "PMU Loop Lost Performance Reason Code States", "PPM Target as % of Max GPU Power", "GPU Throttler Counters", "THM Counters"].contains(sub) else { continue }
        let n = IOReportStateGetCount(item)
        if n <= 0 { print("  \(sub)|\(name) value=\(IOReportSimpleGetIntegerValue(item, 0))"); continue }
        var parts: [String] = []
        for i in 0..<n {
            let sn = IOReportStateGetNameForIndex(item, i)?.takeUnretainedValue() as String? ?? "?"
            parts.append("\(sn)=\(IOReportStateGetResidency(item, i))")
        }
        print("  \(sub)|\(name): " + parts.joined(separator: " "))
    }
}
