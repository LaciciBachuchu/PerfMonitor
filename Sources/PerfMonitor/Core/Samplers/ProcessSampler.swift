import AppKit
import Darwin

struct ProcessStat: Identifiable, Hashable {
    var id: String            // pid, or app path when grouped
    var pids: [pid_t]
    var name: String
    var appPath: String?      // enclosing .app bundle, if any
    var cpu: Double           // percent of one core (can exceed 100)
    var memory: Double        // bytes (phys footprint)
    var powerW: Double?       // CPU energy rate from the kernel's per-process accounting
    var powerEstimated = false // other users' processes: inferred from CPU time
    var diskBps: Double
    var background: Bool      // clamped to PRIO_DARWIN_BG (E-cores only)
}

/// Per-process CPU, memory, energy and disk I/O via libproc.
final class ProcessSampler {
    private struct Prev { var cpuTime: UInt64; var energy: UInt64; var disk: UInt64 }

    private var prev: [pid_t: Prev] = [:]
    private var names: [pid_t: (name: String, app: String?)] = [:]
    private var prevTime = Date()
    private let ticksToNs: Double = {
        var tb = mach_timebase_info()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom)
    }()

    struct Result {
        var processes: [ProcessStat] = []
        /// Total CPU power: measured for readable processes, CPU-time-scaled for the rest.
        var cpuW = 0.0
    }

    func sample() -> Result {
        let now = Date()
        let dt = max(now.timeIntervalSince(prevTime), 0.001)
        defer { prevTime = now }

        let n = proc_listallpids(nil, 0)
        guard n > 0 else { return Result() }
        var pids = [pid_t](repeating: 0, count: Int(n) + 64)
        let got = proc_listallpids(&pids, Int32(pids.count * MemoryLayout<pid_t>.size))
        pids = Array(pids.prefix(Int(max(got, 0)))).filter { $0 > 0 }

        var next: [pid_t: Prev] = [:]
        var out: [ProcessStat] = []
        out.reserveCapacity(pids.count)
        var measuredW = 0.0, measuredCPU = 0.0

        for pid in pids {
            var cpuTime: UInt64 = 0, energy: UInt64 = 0, disk: UInt64 = 0, mem: UInt64 = 0
            var hasEnergy = false

            var ru = rusage_info_v6()
            let rc = withUnsafeMutablePointer(to: &ru) {
                $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
            }
            if rc == 0 {
                cpuTime = ru.ri_user_time + ru.ri_system_time
                energy = ru.ri_energy_nj
                disk = ru.ri_diskio_bytesread + ru.ri_diskio_byteswritten
                mem = ru.ri_phys_footprint
                hasEnergy = true
            } else {
                // Other users' processes (WindowServer, daemons): task info is still readable.
                var ti = proc_taskinfo()
                let size = Int32(MemoryLayout<proc_taskinfo>.size)
                guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, size) == size else { continue }
                cpuTime = ti.pti_total_user + ti.pti_total_system
                mem = ti.pti_resident_size
            }
            next[pid] = Prev(cpuTime: cpuTime, energy: energy, disk: disk)
            guard let p = prev[pid] else { continue }

            let cpu = Double(cpuTime &- p.cpuTime) * ticksToNs / 1e9 / dt * 100
            let watts = hasEnergy ? Double(energy &- p.energy) / 1e9 / dt : nil
            if let watts { measuredW += watts; measuredCPU += cpu }
            let (name, app) = label(pid)
            out.append(ProcessStat(
                id: "\(pid)", pids: [pid], name: name, appPath: app,
                cpu: max(cpu, 0), memory: Double(mem),
                powerW: watts,
                diskBps: Double(disk &- p.disk) / dt,
                background: ProcessActions.isClamped(pid)
            ))
        }
        prev = next
        names = names.filter { next[$0.key] != nil }

        // Energy per CPU-percent from processes we can measure, applied to those we can't.
        let wattsPerCPU = measuredCPU > 1 ? measuredW / measuredCPU : 0
        var total = measuredW
        for i in out.indices where out[i].powerW == nil {
            let w = out[i].cpu * wattsPerCPU
            out[i].powerW = w
            out[i].powerEstimated = true
            total += w
        }
        return Result(processes: out, cpuW: total)
    }

    private static var displayNames: [String: String] = [:]
    private static let namesLock = NSLock()

    private static func displayName(_ app: String) -> String {
        namesLock.lock(); defer { namesLock.unlock() }
        if let n = displayNames[app] { return n }
        let n = FileManager.default.displayName(atPath: app).replacingOccurrences(of: ".app", with: "")
        displayNames[app] = n
        return n
    }

    /// Merges helper processes into their owning app (Chrome Helper → Chrome).
    static func groupByApp(_ list: [ProcessStat]) -> [ProcessStat] {
        var groups: [String: ProcessStat] = [:]
        var loose: [ProcessStat] = []
        for p in list {
            guard let app = p.appPath else { loose.append(p); continue }
            if var g = groups[app] {
                g.pids += p.pids
                g.cpu += p.cpu
                g.memory += p.memory
                g.diskBps += p.diskBps
                if let w = p.powerW { g.powerW = (g.powerW ?? 0) + w }
                g.powerEstimated = g.powerEstimated || p.powerEstimated
                g.background = g.background && p.background
                groups[app] = g
            } else {
                var g = p
                g.id = app
                g.name = displayName(app)
                groups[app] = g
            }
        }
        return Array(groups.values) + loose
    }

    private func label(_ pid: pid_t) -> (String, String?) {
        if let cached = names[pid] { return cached }
        var buf = [CChar](repeating: 0, count: Int(MAXPATHLEN) * 4)
        let path = proc_pidpath(pid, &buf, UInt32(buf.count)) > 0 ? String(cString: buf) : ""
        var name = NSRunningApplication(processIdentifier: pid)?.localizedName
        if name == nil {
            var nbuf = [CChar](repeating: 0, count: 256)
            proc_name(pid, &nbuf, UInt32(nbuf.count))
            name = String(cString: nbuf)
            if name!.isEmpty { name = (path as NSString).lastPathComponent }
        }
        // Outermost .app bundle in the path.
        var app: String?
        if let r = path.range(of: ".app/") {
            app = String(path[..<r.lowerBound]) + ".app"
        }
        let result = (name ?? "pid \(pid)", app)
        names[pid] = result
        return result
    }
}

enum ProcessActions {
    // getpriority() can't read PRIO_DARWIN_BG back, so remember what we clamped.
    private static var clamped = Set<pid_t>()
    private static let lock = NSLock()

    static func isClamped(_ pid: pid_t) -> Bool {
        lock.lock(); defer { lock.unlock() }
        return clamped.contains(pid)
    }

    /// Clamp to background priority: the scheduler keeps it on E-cores with throttled I/O.
    @discardableResult
    static func setBackground(_ pids: [pid_t], _ on: Bool) -> Bool {
        var ok = true
        for pid in pids {
            guard setpriority(PRIO_DARWIN_PROCESS, id_t(pid), on ? PRIO_DARWIN_BG : 0) == 0 else { ok = false; continue }
            lock.lock()
            if on { clamped.insert(pid) } else { clamped.remove(pid) }
            lock.unlock()
        }
        return ok
    }

    static func terminate(_ pids: [pid_t], force: Bool) {
        for pid in pids {
            if !force, let app = NSRunningApplication(processIdentifier: pid) {
                app.terminate()
            } else {
                kill(pid, force ? SIGKILL : SIGTERM)
            }
        }
    }
}
