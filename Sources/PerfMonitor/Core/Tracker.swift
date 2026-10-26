import Foundation

/// One recorded watch of an app (all its helper processes) or a single process over time.
/// Totals are integrated from per-sample rates; the sample series is downsampled when long.
struct TrackSession: Codable, Identifiable, Hashable {
    struct Sample: Codable, Hashable {
        var t: Date
        var cpuPct: Double          // percent of one core, summed over the app's processes
        var memoryBytes: Double
        var powerW: Double          // CPU energy rate (kernel per-process accounting)
        var gpuPct: Double
        var diskBps: Double
        var netBps: Double
        var processes: Int
    }

    /// Per-process-name share, e.g. which ChatGPT helper did the work.
    struct Part: Codable, Hashable {
        var name: String
        var cpuSeconds = 0.0
        var energyJ = 0.0
        var peakMemoryBytes = 0.0
        var gpuSeconds = 0.0
        var diskBytes = 0.0
        var netInBytes = 0.0
        var netOutBytes = 0.0

        init(name: String) { self.name = name }

        // Sessions saved by older versions lack the later fields.
        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            cpuSeconds = try c.decodeIfPresent(Double.self, forKey: .cpuSeconds) ?? 0
            energyJ = try c.decodeIfPresent(Double.self, forKey: .energyJ) ?? 0
            peakMemoryBytes = try c.decodeIfPresent(Double.self, forKey: .peakMemoryBytes) ?? 0
            gpuSeconds = try c.decodeIfPresent(Double.self, forKey: .gpuSeconds) ?? 0
            diskBytes = try c.decodeIfPresent(Double.self, forKey: .diskBytes) ?? 0
            netInBytes = try c.decodeIfPresent(Double.self, forKey: .netInBytes) ?? 0
            netOutBytes = try c.decodeIfPresent(Double.self, forKey: .netOutBytes) ?? 0
        }
    }

    struct Totals: Codable, Hashable {
        var trackedSeconds = 0.0    // time covered by samples
        var runningSeconds = 0.0    // of which the target was running
        var cpuSeconds = 0.0
        var energyJ = 0.0
        var gpuSeconds = 0.0
        var diskReadBytes = 0.0
        var diskWrittenBytes = 0.0
        var netBytes = 0.0
        var netInBytes: Double?     // nil in sessions saved before the split
        var netOutBytes: Double?
        var peakGpuPct: Double?
        var peakNetBps: Double?
        var peakCpuPct = 0.0
        var peakMemoryBytes = 0.0
        var memoryByteSeconds = 0.0 // for the running average
        var idleWakeups = 0.0
        var systemEnergyJ = 0.0     // whole machine, same window
        var systemCpuSeconds = 0.0  // whole machine, same window
        var powerEstimated = false  // some processes belong to other users: energy inferred from CPU time
    }

    var id: String
    var target: String              // what was asked for
    var name: String                // resolved display name
    var appPath: String?
    var pid: Int32?                 // set when tracking one process
    var startedAt: Date
    var endedAt: Date?
    var plannedSeconds: Double?     // auto-stop after this long
    var includeNetwork = true
    var interrupted = false         // the app quit before the session was stopped
    var cores: Int
    var totals = Totals()
    var parts: [Part] = []
    var samples: [Sample] = []

    var active: Bool { endedAt == nil }
    var elapsed: Double { (endedAt ?? Date()).timeIntervalSince(startedAt) }

    func matches(_ p: ProcessStat) -> Bool {
        if let pid { return p.pids.first == pid }
        if let appPath { return p.appPath == appPath }
        return p.name.caseInsensitiveCompare(name) == .orderedSame
    }
}

/// Owns live and saved sessions. Fed from the sampler queue; read from any thread.
final class Tracker {
    static let maxSamples = 2400
    static var directory: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("PerfMonitor/tracks", isDirectory: true)
    }

    private let lock = NSLock()
    private var sessions: [String: TrackSession] = [:]
    private var lastIngest: Date?
    private var ingests = 0
    private let io = DispatchQueue(label: "perfmonitor.tracks", qos: .utility)
    /// Called on the main queue after a change, with the sessions newest first.
    var onChange: (([TrackSession]) -> Void)?

    init() {
        for var s in Self.loadAll() {
            if s.active {   // left running when the app quit
                s.endedAt = s.samples.last?.t ?? s.startedAt
                s.interrupted = true
                save(s)
            }
            sessions[s.id] = s
        }
    }

    var hasActive: Bool { lock.lock(); defer { lock.unlock() }; return sessions.values.contains(where: \.active) }
    var wantsNetwork: Bool { lock.lock(); defer { lock.unlock() }; return sessions.values.contains { $0.active && $0.includeNetwork } }

    func all() -> [TrackSession] {
        lock.lock(); defer { lock.unlock() }
        return sessions.values.sorted { $0.startedAt > $1.startedAt }
    }

    func get(_ id: String) -> TrackSession? {
        lock.lock(); defer { lock.unlock() }
        return sessions[id]
    }

    enum StartError: Error, CustomStringConvertible {
        case notFound(String), ambiguous(String, [String])
        var description: String {
            switch self {
            case .notFound(let q): "没有 PID 为 \(q) 的进程。"
            case .ambiguous(let q, let names): "「\(q)」匹配到多个：\(names.joined(separator: "、"))。请写得更具体。"
            }
        }
    }

    /// Resolves `target` (app name, process name, bundle path or PID) against what is running now.
    func start(target: String, seconds: Double?, network: Bool, snapshot: Snapshot) -> Result<TrackSession, StartError> {
        let q = target.trimmingCharacters(in: .whitespaces)
        var s = TrackSession(id: Self.newID(), target: q, name: q, startedAt: Date(),
                             plannedSeconds: seconds.flatMap { $0 > 0 ? $0 : nil }, includeNetwork: network,
                             cores: ProcessInfo.processInfo.activeProcessorCount)
        if let pid = Int32(q) {
            guard let p = snapshot.processes.first(where: { $0.pids.first == pid }) else { return .failure(.notFound(q)) }
            s.pid = pid
            s.name = p.name
            s.appPath = p.appPath
        } else if q.hasSuffix(".app"), q.hasPrefix("/") {
            s.appPath = q
            s.name = ProcessSampler.displayName(q)
        } else {
            let exact = snapshot.apps.filter { $0.name.caseInsensitiveCompare(q) == .orderedSame }
                + snapshot.processes.filter { $0.appPath == nil && $0.name.caseInsensitiveCompare(q) == .orderedSame }
            var candidates = exact.isEmpty ? snapshot.apps.filter { $0.name.localizedCaseInsensitiveContains(q) } : exact
            // "Claude" (the app) vs "claude" (a CLI): exact case wins, then a real app bundle.
            for narrow in [{ (p: ProcessStat) in p.name == q }, { (p: ProcessStat) in p.appPath != nil }] {
                let n = candidates.filter(narrow)
                if Set(n.map { $0.appPath ?? $0.name }).count == 1 { candidates = n; break }
            }
            let distinct = Dictionary(grouping: candidates) { $0.appPath ?? $0.name }
            if distinct.count > 1 {
                return .failure(.ambiguous(q, distinct.values.compactMap(\.first?.name).sorted()))
            }
            // Not running yet is fine: the session picks the app up once it launches.
            if let first = candidates.first {
                s.name = first.name
                s.appPath = first.appPath
            }
        }
        lock.lock()
        sessions[s.id] = s
        lock.unlock()
        save(s)
        publish()
        return .success(s)
    }

    @discardableResult
    func stop(_ id: String) -> TrackSession? {
        lock.lock()
        guard var s = sessions[id], s.active else { lock.unlock(); return sessions[id] }
        s.endedAt = Date()
        sessions[id] = s
        lock.unlock()
        save(s)
        publish()
        return s
    }

    func delete(_ id: String) {
        lock.lock()
        sessions[id] = nil
        lock.unlock()
        io.async { try? FileManager.default.removeItem(at: Self.file(id)) }
        publish()
    }

    /// Adds one sample to every active session. Only call with snapshots whose process list was rescanned.
    func ingest(_ snap: Snapshot) {
        lock.lock()
        let dt = lastIngest.map { min(snap.time.timeIntervalSince($0), 30) } ?? 0
        lastIngest = snap.time
        let ids = sessions.values.filter(\.active).map(\.id)
        guard !ids.isEmpty else { lock.unlock(); return }
        ingests += 1
        let persist = ingests % 15 == 0
        var finished: [TrackSession] = []
        var changed: [TrackSession] = []
        for id in ids {
            guard var s = sessions[id] else { continue }
            Self.add(snap, dt: min(dt, max(0, snap.time.timeIntervalSince(s.startedAt))), to: &s)
            if let plan = s.plannedSeconds, snap.time.timeIntervalSince(s.startedAt) >= plan {
                s.endedAt = s.startedAt.addingTimeInterval(plan)
                finished.append(s)
            } else if persist {
                changed.append(s)
            }
            sessions[id] = s
        }
        lock.unlock()
        (finished + changed).forEach(save)
        publish()
    }

    private static func add(_ snap: Snapshot, dt: Double, to s: inout TrackSession) {
        // Started by name before the app was open: bind to its bundle once it shows up.
        if s.pid == nil, s.appPath == nil,
           let app = snap.apps.first(where: { $0.appPath != nil && $0.name.caseInsensitiveCompare(s.name) == .orderedSame }) {
            s.appPath = app.appPath
            s.name = app.name
        }
        let procs = snap.processes.filter(s.matches)
        var sample = TrackSession.Sample(t: snap.time, cpuPct: 0, memoryBytes: 0, powerW: 0, gpuPct: 0, diskBps: 0, netBps: 0, processes: procs.count)
        var wakeups = 0.0, netIn = 0.0, netOut = 0.0
        for p in procs {
            netIn += p.netInBps ?? 0
            netOut += p.netOutBps ?? 0
            sample.cpuPct += p.cpu
            sample.memoryBytes += p.memory
            sample.powerW += p.powerW ?? 0
            sample.gpuPct += p.gpu ?? 0
            sample.diskBps += p.diskBps
            sample.netBps += (p.netInBps ?? 0) + (p.netOutBps ?? 0)
            wakeups += p.idleWakeups ?? 0
            if p.powerEstimated { s.totals.powerEstimated = true }
        }
        var t = s.totals
        if dt > 0 {
            t.trackedSeconds += dt
            if !procs.isEmpty { t.runningSeconds += dt }
            t.cpuSeconds += sample.cpuPct / 100 * dt
            t.energyJ += sample.powerW * dt
            t.gpuSeconds += sample.gpuPct / 100 * dt
            t.diskReadBytes += procs.reduce(0) { $0 + $1.diskReadBps } * dt
            t.diskWrittenBytes += procs.reduce(0) { $0 + $1.diskWriteBps } * dt
            t.netBytes += sample.netBps * dt
            t.netInBytes = (t.netInBytes ?? 0) + netIn * dt
            t.netOutBytes = (t.netOutBytes ?? 0) + netOut * dt
            t.memoryByteSeconds += sample.memoryBytes * dt
            t.idleWakeups += wakeups * dt
            t.systemEnergyJ += snap.totalW * dt
            t.systemCpuSeconds += snap.system.cpuTotal * Double(s.cores) * dt
            for p in procs {
                let i = s.parts.firstIndex { $0.name == p.name } ?? { s.parts.append(.init(name: p.name)); return s.parts.count - 1 }()
                s.parts[i].cpuSeconds += p.cpu / 100 * dt
                s.parts[i].energyJ += (p.powerW ?? 0) * dt
                s.parts[i].peakMemoryBytes = max(s.parts[i].peakMemoryBytes, p.memory)
                s.parts[i].gpuSeconds += (p.gpu ?? 0) / 100 * dt
                s.parts[i].diskBytes += p.diskBps * dt
                s.parts[i].netInBytes += (p.netInBps ?? 0) * dt
                s.parts[i].netOutBytes += (p.netOutBps ?? 0) * dt
            }
            s.parts.sort { $0.cpuSeconds > $1.cpuSeconds }
        }
        t.peakCpuPct = max(t.peakCpuPct, sample.cpuPct)
        t.peakMemoryBytes = max(t.peakMemoryBytes, sample.memoryBytes)
        t.peakGpuPct = max(t.peakGpuPct ?? 0, sample.gpuPct)
        t.peakNetBps = max(t.peakNetBps ?? 0, sample.netBps)
        s.totals = t
        s.samples.append(sample)
        if s.samples.count > maxSamples { s.samples = halve(s.samples) }
    }

    /// Merges neighbouring samples; peaks survive in the totals.
    private static func halve(_ list: [TrackSession.Sample]) -> [TrackSession.Sample] {
        stride(from: 0, to: list.count - 1, by: 2).map { i in
            let a = list[i], b = list[i + 1]
            return .init(t: b.t, cpuPct: (a.cpuPct + b.cpuPct) / 2, memoryBytes: max(a.memoryBytes, b.memoryBytes),
                         powerW: (a.powerW + b.powerW) / 2, gpuPct: (a.gpuPct + b.gpuPct) / 2,
                         diskBps: (a.diskBps + b.diskBps) / 2, netBps: (a.netBps + b.netBps) / 2,
                         processes: max(a.processes, b.processes))
        } + (list.count % 2 == 1 ? [list.last!] : [])
    }

    private func publish() {
        guard let onChange else { return }
        let list = all()
        DispatchQueue.main.async { onChange(list) }
    }

    // MARK: Storage

    private static func newID() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: Date()) + "-" + String(UUID().uuidString.prefix(4)).lowercased()
    }

    static func file(_ id: String) -> URL { directory.appendingPathComponent(id + ".json") }

    private func save(_ s: TrackSession) {
        io.async {
            try? FileManager.default.createDirectory(at: Self.directory, withIntermediateDirectories: true)
            try? JSON.encode(s, pretty: false).write(to: Self.file(s.id), options: .atomic)
        }
    }

    /// Saved sessions, readable without the app (CLI fallback).
    static func loadAll() -> [TrackSession] {
        let files = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)) ?? []
        return files.filter { $0.pathExtension == "json" }.compactMap {
            guard let d = try? Data(contentsOf: $0) else { return nil }
            return CLI.decode(TrackSession.self, d)
        }
        .sorted { $0.startedAt > $1.startedAt }
    }
}

/// Agent-facing view of a session: derived averages and shares spelled out.
struct TrackReport: Codable {
    struct Part: Codable {
        var name: String
        var cpuSeconds: Double
        var energyJ: Double
        var peakMemoryBytes: Double
        var gpuSeconds: Double
        var diskBytes: Double
        var networkInBytes: Double?
        var networkOutBytes: Double?
    }
    var id: String
    var target: String
    var name: String
    var appPath: String?
    var pid: Int32?
    var status: String              // recording | finished | interrupted
    var startedAt: Date
    var endedAt: Date?
    var plannedSeconds: Double?
    var durationSeconds: Double
    var runningSeconds: Double
    var summary: String
    var avgCpuPct: Double           // percent of one core
    var peakCpuPct: Double
    var shareOfMachineCpuPct: Double // of all cores' capacity
    var shareOfUsedCpuPct: Double   // of the CPU time actually used by everything
    var cpuSeconds: Double
    var avgMemoryBytes: Double
    var peakMemoryBytes: Double
    var energyJ: Double
    var energyWh: Double
    var avgPowerW: Double
    var shareOfSystemEnergyPct: Double
    var powerEstimated: Bool
    var gpuSeconds: Double
    var avgGpuPct: Double
    var diskReadBytes: Double
    var diskWrittenBytes: Double
    var networkBytes: Double?
    var networkInBytes: Double?
    var networkOutBytes: Double?
    var avgNetworkBps: Double?
    var peakNetworkBps: Double?
    var peakGpuPct: Double?
    var idleWakeupsPerSec: Double
    var systemAvgPowerW: Double
    var processes: [Part]
    var samples: [TrackSession.Sample]?

    init(_ s: TrackSession, includeSamples: Bool) {
        let t = s.totals
        let dur = max(t.trackedSeconds, 0.001)
        let run = max(t.runningSeconds, 0.001)
        id = s.id; target = s.target; name = s.name; appPath = s.appPath; pid = s.pid
        status = s.active ? "recording" : (s.interrupted ? "interrupted" : "finished")
        startedAt = s.startedAt; endedAt = s.endedAt; plannedSeconds = s.plannedSeconds
        durationSeconds = s.elapsed
        runningSeconds = t.runningSeconds
        avgCpuPct = t.cpuSeconds / dur * 100
        peakCpuPct = t.peakCpuPct
        shareOfMachineCpuPct = t.cpuSeconds / (dur * Double(max(s.cores, 1))) * 100
        shareOfUsedCpuPct = t.systemCpuSeconds > 0 ? min(100, t.cpuSeconds / t.systemCpuSeconds * 100) : 0
        cpuSeconds = t.cpuSeconds
        avgMemoryBytes = t.memoryByteSeconds / run
        peakMemoryBytes = t.peakMemoryBytes
        energyJ = t.energyJ
        energyWh = t.energyJ / 3600
        avgPowerW = t.energyJ / dur
        shareOfSystemEnergyPct = t.systemEnergyJ > 0 ? t.energyJ / t.systemEnergyJ * 100 : 0
        powerEstimated = t.powerEstimated
        gpuSeconds = t.gpuSeconds
        avgGpuPct = t.gpuSeconds / dur * 100
        diskReadBytes = t.diskReadBytes
        diskWrittenBytes = t.diskWrittenBytes
        networkBytes = s.includeNetwork ? t.netBytes : nil
        networkInBytes = s.includeNetwork ? t.netInBytes : nil
        networkOutBytes = s.includeNetwork ? t.netOutBytes : nil
        avgNetworkBps = s.includeNetwork ? t.netBytes / dur : nil
        peakNetworkBps = s.includeNetwork ? t.peakNetBps : nil
        peakGpuPct = t.peakGpuPct
        idleWakeupsPerSec = t.idleWakeups / dur
        systemAvgPowerW = t.systemEnergyJ / dur
        let net = s.includeNetwork
        processes = s.parts.prefix(12).map {
            Part(name: $0.name, cpuSeconds: $0.cpuSeconds, energyJ: $0.energyJ, peakMemoryBytes: $0.peakMemoryBytes,
                 gpuSeconds: $0.gpuSeconds, diskBytes: $0.diskBytes,
                 networkInBytes: net ? $0.netInBytes : nil, networkOutBytes: net ? $0.netOutBytes : nil)
        }
        samples = includeSamples ? s.samples : nil

        let mins = Int(dur / 60), secs = Int(dur) % 60
        var line = "\(name) 在\(mins > 0 ? " \(mins) 分 \(secs) 秒" : " \(secs) 秒")内"
        if t.runningSeconds < 0.5 { line += "（期间没有运行）" }
        else if t.runningSeconds < dur * 0.98 { line += "（运行了 \(Int(run / 60)) 分 \(Int(run) % 60) 秒）" }
        line += String(format: "平均占用 CPU %.1f%%（单核为 100%%，占整机算力 %.1f%%，峰值 %.0f%%），", avgCpuPct, shareOfMachineCpuPct, peakCpuPct)
        line += "内存平均 \(ByteFormat.short(avgMemoryBytes))、峰值 \(ByteFormat.short(peakMemoryBytes))，"
        line += String(format: "CPU 能耗 %@（平均 %.2f W，约占整机能耗 %.1f%%）", Fmt.energy(energyJ), avgPowerW, shareOfSystemEnergyPct)
        line += String(format: "，GPU 平均 %.1f%%（峰值 %.0f%%）", avgGpuPct, peakGpuPct ?? 0)
        line += "，磁盘读 \(ByteFormat.short(diskReadBytes))、写 \(ByteFormat.short(diskWrittenBytes))"
        if let i = networkInBytes, let o = networkOutBytes {
            line += "，网络下载 \(ByteFormat.short(i))、上传 \(ByteFormat.short(o))（平均 \(ByteFormat.rate(avgNetworkBps ?? 0))）"
        } else if let n = networkBytes { line += "，网络 \(ByteFormat.short(n))" }
        summary = line + "。"
    }
}
