import CSensors
import Darwin
import Foundation
import IOKit
import IOKit.ps

/// CPU load, memory, thermal pressure, GPU utilisation, disk I/O and battery.
final class SystemSampler {
    enum ThermalPressure: Int, Comparable {
        case nominal = 0, moderate, heavy, trapping, sleeping
        static func < (a: Self, b: Self) -> Bool { a.rawValue < b.rawValue }
        var label: String {
            switch self {
            case .nominal: "正常"
            case .moderate: "中等"
            case .heavy: "严重"
            case .trapping: "临界"
            case .sleeping: "即将休眠"
            }
        }
    }

    struct Memory {
        var total: Double = 0, used: Double = 0, app: Double = 0, wired: Double = 0, compressed: Double = 0
        var swapUsed: Double = 0, swapTotal: Double = 0
        var swapInsPerSec: Double = 0, swapOutsPerSec: Double = 0   // pages/s
        /// kern.memorystatus_vm_pressure_level: 1 normal, 2 warning, 4 critical
        var pressureLevel: Int = 1
    }


    struct Result {
        var cpuTotal = 0.0          // 0...1 over all cores
        var cpuUser = 0.0, cpuSystem = 0.0
        var memory = Memory()
        var thermal = ThermalPressure.nominal
        var gpuUtil: Double?        // 0...1
        var diskReadBps = 0.0, diskWriteBps = 0.0
        var lowPowerMode = false
    }

    private var prevTicks: [UInt32] = []
    private var prevVM: vm_statistics64?
    private var prevDisk: (read: Double, write: Double)?
    private var prevTime = Date()
    private var thermalToken: Int32 = 0
    private let pageSize = Double(vm_kernel_page_size)

    init() {
        notify_register_check("com.apple.system.thermalpressurelevel", &thermalToken)
    }

    func sample() -> Result {
        let now = Date()
        let dt = max(now.timeIntervalSince(prevTime), 0.001)
        defer { prevTime = now }

        var r = Result()
        (r.cpuTotal, r.cpuUser, r.cpuSystem) = cpuLoad()
        r.memory = memory(dt: dt)
        var state: UInt64 = 0
        notify_get_state(thermalToken, &state)
        r.thermal = ThermalPressure(rawValue: Int(state)) ?? .nominal
        r.gpuUtil = gpuUtilisation()
        if let disk = diskBytes() {
            if let prev = prevDisk {
                r.diskReadBps = max(0, disk.read - prev.read) / dt
                r.diskWriteBps = max(0, disk.write - prev.write) / dt
            }
            prevDisk = disk
        }
        r.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
        return r
    }

    // MARK: - CPU

    private func cpuLoad() -> (Double, Double, Double) {
        var count: natural_t = 0
        var info: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0
        guard host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO, &count, &info, &infoCount) == KERN_SUCCESS,
              let info else { return (0, 0, 0) }
        defer { vm_deallocate(mach_task_self_, vm_address_t(bitPattern: info), vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride)) }

        let ticks = (0..<Int(infoCount)).map { UInt32(bitPattern: info[$0]) }
        defer { prevTicks = ticks }
        guard prevTicks.count == ticks.count else { return (0, 0, 0) }

        var busy: UInt64 = 0, total: UInt64 = 0, user: UInt64 = 0, system: UInt64 = 0
        for core in 0..<Int(count) {
            let base = core * Int(CPU_STATE_MAX)
            for s in 0..<Int(CPU_STATE_MAX) {
                let d = UInt64(ticks[base + s] &- prevTicks[base + s])
                total += d
                if s != Int(CPU_STATE_IDLE) { busy += d }
                if s == Int(CPU_STATE_USER) || s == Int(CPU_STATE_NICE) { user += d }
                if s == Int(CPU_STATE_SYSTEM) { system += d }
            }
        }
        guard total > 0 else { return (0, 0, 0) }
        return (Double(busy) / Double(total), Double(user) / Double(total), Double(system) / Double(total))
    }

    // MARK: - Memory

    private func memory(dt: Double) -> Memory {
        var m = Memory()
        var size: UInt64 = 0
        var len = MemoryLayout<UInt64>.size
        sysctlbyname("hw.memsize", &size, &len, nil, 0)
        m.total = Double(size)

        var vm = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let ok = withUnsafeMutablePointer(to: &vm) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        if ok == KERN_SUCCESS {
            // Same definition as Activity Monitor's "Memory Used".
            m.app = Double(vm.internal_page_count - vm.purgeable_count) * pageSize
            m.wired = Double(vm.wire_count) * pageSize
            m.compressed = Double(vm.compressor_page_count) * pageSize
            m.used = m.app + m.wired + m.compressed
            if let prev = prevVM {
                m.swapInsPerSec = Double(vm.swapins &- prev.swapins) / dt
                m.swapOutsPerSec = Double(vm.swapouts &- prev.swapouts) / dt
            }
            prevVM = vm
        }

        var swap = xsw_usage()
        len = MemoryLayout<xsw_usage>.size
        if sysctlbyname("vm.swapusage", &swap, &len, nil, 0) == 0 {
            m.swapUsed = Double(swap.xsu_used)
            m.swapTotal = Double(swap.xsu_total)
        }
        var level: Int32 = 1
        len = MemoryLayout<Int32>.size
        sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &len, nil, 0)
        m.pressureLevel = Int(level)
        return m
    }

    // MARK: - IORegistry

    private lazy var gpuService: io_service_t = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))

    private func gpuUtilisation() -> Double? {
        guard gpuService != 0,
              let stats = IORegistryEntryCreateCFProperty(gpuService, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue() as? [String: Any] else { return nil }
        return (stats["Device Utilization %"] as? NSNumber).map { $0.doubleValue / 100 }
    }

    private func diskBytes() -> (read: Double, write: Double)? {
        var read = 0.0, write = 0.0, found = false
        _ = forEachService("IOBlockStorageDriver") { props -> Double? in
            if let stats = props["Statistics"] as? [String: Any] {
                read += stats["Bytes (Read)"] as? Double ?? 0
                write += stats["Bytes (Write)"] as? Double ?? 0
                found = true
            }
            return nil
        }
        return found ? (read, write) : nil
    }


    /// Calls `body` with each matching service's properties; returns the first non-nil result.
    private func forEachService<T>(_ cls: String, _ body: ([String: Any]) -> T?) -> T? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(cls), &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(entry, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
                  let dict = props?.takeRetainedValue() as? [String: Any] else { continue }
            if let v = body(dict) { return v }
        }
        return nil
    }
}
