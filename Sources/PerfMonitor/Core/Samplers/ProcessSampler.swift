import AppKit
import Darwin
import IOKit
import IOKit.pwr_mgt

struct ProcessStat: Identifiable, Hashable {
    var id: String            // pid, or app path when grouped
    var pids: [pid_t]
    var name: String
    var appPath: String?      // enclosing .app bundle, if any
    var path = ""
    var ppid: pid_t = 0
    var uid: uid_t = 0
    var user = ""
    var startTime: Date?
    var isOwn = false         // same user as us: full rusage detail is readable
    var translated = false    // running under Rosetta
    var hasWindow = false     // regular (Dock) app

    // CPU
    var cpu: Double           // percent of one core (can exceed 100)
    var cpuTime = 0.0         // seconds since launch
    var threads = -1          // -1: unknown (other users' processes)
    var idleWakeups: Double?  // package idle wakeups per second (own processes)
    var gpu: Double?          // percent of GPU time
    var gpuTime: Double?      // seconds since launch

    // Memory (bytes)
    var memory: Double        // phys footprint (resident for other users' processes)
    var resident = 0.0
    var peakMemory: Double?

    // Energy
    var powerW: Double?       // CPU energy rate from the kernel's per-process accounting
    var powerEstimated = false // other users' processes: inferred from CPU time
    var energyJ: Double?      // cumulative since launch
    var preventingSleep = false

    // Disk
    var diskBps: Double
    var diskReadBps = 0.0, diskWriteBps = 0.0
    var diskRead: Double?, diskWritten: Double?

    // Network (only while the network view is open)
    var netInBps: Double?, netOutBps: Double?
    var netIn: Double?, netOut: Double?

    var background: Bool      // clamped to PRIO_DARWIN_BG (E-cores only)

    /// Average power since the process started.
    var avgPowerW: Double? {
        guard let e = energyJ, let start = startTime else { return nil }
        let age = Date().timeIntervalSince(start)
        return age > 1 ? e / age : nil
    }
}

/// Per-process CPU, memory, energy, disk, GPU and (optionally) network via libproc,
/// sysctl, IORegistry and nettop. Nothing here needs root.
final class ProcessSampler {
    private struct Prev {
        var cpuTime: UInt64, energy: UInt64, read: UInt64, written: UInt64, wakeups: UInt64
    }
    private struct Info { var ppid: pid_t; var uid: uid_t; var start: Date?; var translated: Bool }

    private var prev: [pid_t: Prev] = [:]
    private var names: [pid_t: (name: String, app: String?, path: String)] = [:]
    private var users: [uid_t: String] = [:]
    private var prevTime = Date()
    private var tick = 0
    private var sleepers = Set<pid_t>()
    private var windowed = Set<pid_t>()
    private let gpu = GPUClientSampler()
    private let net = NetworkSampler()
    private let me = getuid()
    private let ticksToSec: Double = {
        var tb = mach_timebase_info()
        mach_timebase_info(&tb)
        return Double(tb.numer) / Double(tb.denom) / 1e9
    }()

    /// Set while a view needs per-process network numbers (costs ~30 ms of CPU per sample).
    var networkEnabled = false

    struct Result {
        var processes: [ProcessStat] = []
        /// Total CPU power: measured for readable processes, CPU-time-scaled for the rest.
        var cpuW = 0.0
    }

    func sample() -> Result {
        let now = Date()
        let dt = max(now.timeIntervalSince(prevTime), 0.001)
        defer { prevTime = now; tick += 1 }

        let infos = Self.kinfo()
        guard !infos.isEmpty else { return Result() }
        if tick % 5 == 0 {
            sleepers = Self.sleepAssertionPIDs()
            windowed = Set(NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }.map(\.processIdentifier))
        }
        let gpuTimes = gpu.sample(dt: dt)
        let netRates = networkEnabled ? net.sample(dt: dt) : [:]

        var next: [pid_t: Prev] = [:]
        var out: [ProcessStat] = []
        out.reserveCapacity(infos.count)
        var measuredW = 0.0, measuredCPU = 0.0

        var unreadable: [(pid_t, Info)] = []
        for (pid, info) in infos where pid > 0 {
            var ti = proc_taskinfo()
            let tsize = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &ti, tsize) == tsize else {
                unreadable.append((pid, info))
                continue
            }
            var cur = Prev(cpuTime: ti.pti_total_user + ti.pti_total_system, energy: 0, read: 0, written: 0, wakeups: 0)
            var footprint = Double(ti.pti_resident_size)
            var peak: Double?
            var own = false

            if info.uid == me {
                var ru = rusage_info_v6()
                let rc = withUnsafeMutablePointer(to: &ru) {
                    $0.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { proc_pid_rusage(pid, RUSAGE_INFO_V6, $0) }
                }
                if rc == 0 {
                    own = true
                    cur.energy = ru.ri_energy_nj
                    cur.read = ru.ri_diskio_bytesread
                    cur.written = ru.ri_diskio_byteswritten
                    cur.wakeups = ru.ri_pkg_idle_wkups
                    footprint = Double(ru.ri_phys_footprint)
                    peak = Double(ru.ri_lifetime_max_phys_footprint)
                }
            }
            next[pid] = cur
            guard let p = prev[pid] else { continue }

            let cpu = Double(cur.cpuTime &- p.cpuTime) * ticksToSec / dt * 100
            let watts = own ? Double(cur.energy &- p.energy) / 1e9 / dt : nil
            if let watts { measuredW += watts; measuredCPU += cpu }
            let (name, app, path) = label(pid)
            let readBps = own ? Double(cur.read &- p.read) / dt : 0
            let writeBps = own ? Double(cur.written &- p.written) / dt : 0
            let g = gpuTimes[pid]
            let n = netRates[pid]

            out.append(ProcessStat(
                id: "\(pid)", pids: [pid], name: name, appPath: app, path: path,
                ppid: info.ppid, uid: info.uid, user: user(info.uid), startTime: info.start,
                isOwn: own, translated: info.translated, hasWindow: windowed.contains(pid),
                cpu: max(cpu, 0), cpuTime: Double(cur.cpuTime) * ticksToSec, threads: Int(ti.pti_threadnum),
                idleWakeups: own ? Double(cur.wakeups &- p.wakeups) / dt : nil,
                gpu: g?.pct, gpuTime: g?.total,
                memory: footprint, resident: Double(ti.pti_resident_size), peakMemory: peak,
                powerW: watts, energyJ: own ? Double(cur.energy) / 1e9 : nil,
                preventingSleep: sleepers.contains(pid),
                diskBps: readBps + writeBps, diskReadBps: readBps, diskWriteBps: writeBps,
                diskRead: own ? Double(cur.read) : nil, diskWritten: own ? Double(cur.written) : nil,
                netInBps: n?.inBps, netOutBps: n?.outBps, netIn: n?.inTotal, netOut: n?.outTotal,
                background: ProcessActions.isClamped(pid)
            ))
        }
        // Root and other users' processes (WindowServer, daemons) refuse proc_pidinfo without
        // root; Apple's entitled `ps` can still read their CPU time and resident memory.
        if !unreadable.isEmpty {
            let ps = Self.psStats()
            for (pid, info) in unreadable {
                guard let (cpuSec, rss) = ps[pid] else { continue }
                let cpuTicks = UInt64(cpuSec / ticksToSec)
                next[pid] = Prev(cpuTime: cpuTicks, energy: 0, read: 0, written: 0, wakeups: 0)
                guard let p = prev[pid] else { continue }
                let cpu = Double(cpuTicks &- p.cpuTime) * ticksToSec / dt * 100
                let (name, app, path) = label(pid)
                let g = gpuTimes[pid]
                let n = netRates[pid]
                out.append(ProcessStat(
                    id: "\(pid)", pids: [pid], name: name, appPath: app, path: path,
                    ppid: info.ppid, uid: info.uid, user: user(info.uid), startTime: info.start,
                    translated: info.translated, hasWindow: windowed.contains(pid),
                    cpu: max(min(cpu, 100 * 64), 0), cpuTime: cpuSec,
                    gpu: g?.pct, gpuTime: g?.total,
                    memory: rss, resident: rss,
                    preventingSleep: sleepers.contains(pid),
                    diskBps: 0,
                    netInBps: n?.inBps, netOutBps: n?.outBps, netIn: n?.inTotal, netOut: n?.outTotal,
                    background: false
                ))
            }
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

    // MARK: - Grouping

    private static var displayNames: [String: String] = [:]
    private static let namesLock = NSLock()

    static func displayName(_ app: String) -> String {
        namesLock.lock(); defer { namesLock.unlock() }
        if let n = displayNames[app] { return n }
        let n = FileManager.default.displayName(atPath: app).replacingOccurrences(of: ".app", with: "")
        displayNames[app] = n
        return n
    }

    /// Merges helper processes into their owning app (Chrome Helper → Chrome).
    static func groupByApp(_ list: [ProcessStat]) -> [ProcessStat] {
        func add(_ a: Double?, _ b: Double?) -> Double? { a == nil && b == nil ? nil : (a ?? 0) + (b ?? 0) }
        var groups: [String: ProcessStat] = [:]
        var loose: [ProcessStat] = []
        for p in list {
            guard let app = p.appPath else { loose.append(p); continue }
            if var g = groups[app] {
                g.pids += p.pids
                g.cpu += p.cpu
                g.cpuTime += p.cpuTime
                if p.threads >= 0 { g.threads = max(g.threads, 0) + p.threads }
                g.idleWakeups = add(g.idleWakeups, p.idleWakeups)
                g.gpu = add(g.gpu, p.gpu)
                g.gpuTime = add(g.gpuTime, p.gpuTime)
                g.memory += p.memory
                g.resident += p.resident
                g.peakMemory = add(g.peakMemory, p.peakMemory)
                g.powerW = add(g.powerW, p.powerW)
                g.powerEstimated = g.powerEstimated || p.powerEstimated
                g.energyJ = add(g.energyJ, p.energyJ)
                g.preventingSleep = g.preventingSleep || p.preventingSleep
                g.diskBps += p.diskBps
                g.diskReadBps += p.diskReadBps
                g.diskWriteBps += p.diskWriteBps
                g.diskRead = add(g.diskRead, p.diskRead)
                g.diskWritten = add(g.diskWritten, p.diskWritten)
                g.netInBps = add(g.netInBps, p.netInBps)
                g.netOutBps = add(g.netOutBps, p.netOutBps)
                g.netIn = add(g.netIn, p.netIn)
                g.netOut = add(g.netOut, p.netOut)
                g.hasWindow = g.hasWindow || p.hasWindow
                g.translated = g.translated || p.translated
                g.background = g.background && p.background
                // The app's own executable (earliest start) represents the group.
                if let s = p.startTime, s < (g.startTime ?? .distantFuture) {
                    g.startTime = s; g.ppid = p.ppid; g.path = p.path
                }
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

    // MARK: - Helpers

    private func label(_ pid: pid_t) -> (String, String?, String) {
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
        let result = (name ?? "pid \(pid)", app, path)
        names[pid] = result
        return result
    }

    /// pid → (CPU seconds, resident bytes) for every process, via /bin/ps (~20 ms).
    private static func psStats() -> [pid_t: (Double, Double)] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/ps")
        p.arguments = ["-axo", "pid=,time=,rss="]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        var out: [pid_t: (Double, Double)] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let f = line.split(separator: " ", omittingEmptySubsequences: true)
            guard f.count >= 3, let pid = pid_t(f[0]), let rssKB = Double(f[2]) else { continue }
            out[pid] = (cpuSeconds(String(f[1])), rssKB * 1024)
        }
        return out
    }

    /// Parses ps TIME: "[dd-][hh:]mm:ss.cc".
    private static func cpuSeconds(_ t: String) -> Double {
        var days = 0.0, rest = Substring(t)
        if let dash = t.firstIndex(of: "-") { days = Double(t[..<dash]) ?? 0; rest = t[t.index(after: dash)...] }
        var total = 0.0
        for part in rest.split(separator: ":") { total = total * 60 + (Double(part) ?? 0) }
        return days * 86400 + total
    }

    private func user(_ uid: uid_t) -> String {
        if let u = users[uid] { return u }
        let name = getpwuid(uid).flatMap { String(cString: $0.pointee.pw_name) } ?? "\(uid)"
        users[uid] = name
        return name
    }

    /// One sysctl for every process: parent, owner, start time, Rosetta flag.
    private static func kinfo() -> [(pid_t, Info)] {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_ALL]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0 else { return [] }
        size += size / 8
        var list = [kinfo_proc](repeating: kinfo_proc(), count: size / MemoryLayout<kinfo_proc>.stride)
        guard sysctl(&mib, 3, &list, &size, nil, 0) == 0 else { return [] }
        let count = size / MemoryLayout<kinfo_proc>.stride
        return list.prefix(count).map { k in
            let tv = k.kp_proc.p_un.__p_starttime
            let start = tv.tv_sec > 0 ? Date(timeIntervalSince1970: Double(tv.tv_sec) + Double(tv.tv_usec) / 1e6) : nil
            return (k.kp_proc.p_pid, Info(ppid: k.kp_eproc.e_ppid, uid: k.kp_eproc.e_ucred.cr_uid, start: start,
                                         translated: k.kp_proc.p_flag & P_TRANSLATED != 0))
        }
    }

    /// Processes holding power assertions that keep the Mac (or display) awake.
    private static func sleepAssertionPIDs() -> Set<pid_t> {
        var dict: Unmanaged<CFDictionary>?
        guard IOPMCopyAssertionsByProcess(&dict) == kIOReturnSuccess,
              let map = dict?.takeRetainedValue() as? [NSNumber: [[String: Any]]] else { return [] }
        let blocking: Set<String> = ["PreventUserIdleSystemSleep", "PreventUserIdleDisplaySleep", "PreventSystemSleep", "NoIdleSleepAssertion", "NoDisplaySleepAssertion"]
        return Set(map.compactMap { pid, list in
            list.contains { blocking.contains($0["AssertType"] as? String ?? "") } ? pid.int32Value : nil
        })
    }
}

/// Per-process GPU time from the AGX driver's user clients ("AppUsage" → accumulatedGPUTime, ns).
final class GPUClientSampler {
    private var prev: [pid_t: Double] = [:]

    func sample(dt: Double) -> [pid_t: (pct: Double, total: Double)] {
        var totals: [pid_t: Double] = [:]
        // User clients aren't registered services, so walk the accelerator's children instead of matching.
        let accel = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOAccelerator"))
        guard accel != 0 else { return [:] }
        defer { IOObjectRelease(accel) }
        var iterator: io_iterator_t = 0
        guard IORegistryEntryGetChildIterator(accel, kIOServicePlane, &iterator) == KERN_SUCCESS else { return [:] }
        defer { IOObjectRelease(iterator) }
        while case let entry = IOIteratorNext(iterator), entry != 0 {
            defer { IOObjectRelease(entry) }
            guard let creator = IORegistryEntryCreateCFProperty(entry, "IOUserClientCreator" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? String,
                  let pidText = creator.split(separator: ",").first?.split(separator: " ").last,
                  let pid = pid_t(pidText),
                  let usage = IORegistryEntryCreateCFProperty(entry, "AppUsage" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [[String: Any]] else { continue }
            let ns = usage.reduce(0.0) { $0 + (($1["accumulatedGPUTime"] as? NSNumber)?.doubleValue ?? 0) }
            totals[pid, default: 0] += ns / 1e9
        }
        defer { prev = totals }
        var out: [pid_t: (Double, Double)] = [:]
        for (pid, t) in totals {
            let pct = prev[pid].map { max(0, t - $0) / dt * 100 } ?? 0
            out[pid] = (min(pct, 100), t)
        }
        return out
    }
}

/// Per-process network bytes via `nettop` (no root needed). One run ≈ 30 ms of CPU,
/// so it only runs while a view asks for it.
final class NetworkSampler {
    private var prev: [pid_t: (Double, Double)] = [:]

    func sample(dt: Double) -> [pid_t: (inBps: Double, outBps: Double, inTotal: Double, outTotal: Double)] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/nettop")
        p.arguments = ["-P", "-L", "1", "-x", "-n", "-J", "bytes_in,bytes_out"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return [:] }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()

        var totals: [pid_t: (Double, Double)] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n").dropFirst() {
            let cols = line.split(separator: ",", omittingEmptySubsequences: false)
            guard cols.count >= 3, let dot = cols[0].lastIndex(of: "."),
                  let pid = pid_t(cols[0][cols[0].index(after: dot)...]),
                  let i = Double(cols[1]), let o = Double(cols[2]) else { continue }
            totals[pid] = (i, o)
        }
        defer { prev = totals }
        var out: [pid_t: (Double, Double, Double, Double)] = [:]
        for (pid, t) in totals {
            let p = prev[pid]
            out[pid] = (p.map { max(0, t.0 - $0.0) / dt } ?? 0, p.map { max(0, t.1 - $0.1) / dt } ?? 0, t.0, t.1)
        }
        return out
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

    static let signals: [(String, Int32)] = [
        ("挂起 (SIGSTOP)", SIGSTOP), ("继续 (SIGCONT)", SIGCONT), ("挂断 (SIGHUP)", SIGHUP),
        ("中断 (SIGINT)", SIGINT), ("退出 (SIGQUIT)", SIGQUIT), ("终止 (SIGTERM)", SIGTERM),
        ("强制结束 (SIGKILL)", SIGKILL), ("用户信号 1 (SIGUSR1)", SIGUSR1), ("用户信号 2 (SIGUSR2)", SIGUSR2),
    ]

    /// Returns nil on success, or the error text (e.g. no permission for other users' processes).
    static func send(_ signal: Int32, to pids: [pid_t]) -> String? {
        for pid in pids where kill(pid, signal) != 0 {
            return String(cString: strerror(errno))
        }
        return nil
    }
}
