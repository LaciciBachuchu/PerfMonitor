import Foundation
import Observation

struct Snapshot {
    var time = Date()
    var io = IOReportSampler.Result()
    var sensors = SensorSampler.Result()
    var system = SystemSampler.Result()
    var power = PowerSampler.Result()
    var processes: [ProcessStat] = []
    var apps: [ProcessStat] = []        // processes grouped by owning app
    var findings: [Finding] = []
    var powerMode = PowerMode.automatic

    /// Best available whole-system power figure.
    var totalW: Double {
        sensors.systemW ?? power.systemLoadW ?? (io.cpuW + io.gpuW + io.aneW + io.dramW)
    }
    /// Hottest compute temperature.
    var hottest: Double? {
        [sensors.pCores?.max, sensors.eCores?.max, sensors.gpu?.max, sensors.soc?.max].compactMap { $0 }.max()
    }
    var socTemp: Double? { sensors.soc?.avg ?? sensors.pCores?.avg }
    var gpuUtil: Double { system.gpuUtil ?? io.gpu.active }
}

/// UI-free sampling pipeline shared by the app, the CLI and the MCP server.
/// Not thread-safe: call `sample()` from one queue.
final class Engine {
    let io = IOReportSampler()
    private let sensors = SensorSampler()
    private let system = SystemSampler()
    private let power = PowerSampler()
    private let procs = ProcessSampler()
    private lazy var catalog = SensorCatalog()
    private var recent: [Snapshot] = []
    private var last = Snapshot()
    private var lastProcessCPUW = 0.0
    /// When nothing shows the process list (dashboard hidden), scan processes only every
    /// third tick: the ~450-process scan is the largest part of the sampling cost.
    var lightMode = false
    var networkEnabled: Bool {
        get { procs.networkEnabled }
        set { procs.networkEnabled = newValue }
    }
    private var tick = 0
    var powerMode = PowerMode.automatic

    init() {
        // Prime the delta-based samplers.
        _ = io.sample(); _ = system.sample(); _ = procs.sample()
    }

    func sample() -> Snapshot {
        var s = Snapshot()
        s.io = io.sample() ?? last.io
        s.sensors = sensors.sample()
        s.system = system.sample()
        s.power = power.sample()
        tick += 1
        if !lightMode || tick % 3 == 0 || last.processes.isEmpty {
            let p = procs.sample()
            s.processes = p.processes
            s.apps = ProcessSampler.groupByApp(p.processes)
            lastProcessCPUW = p.cpuW
        } else {
            s.processes = last.processes
            s.apps = last.apps
        }
        if s.io.cpuPowerSource.isEmpty {
            s.io.cpuW = lastProcessCPUW
            s.io.cpuPowerSource = "process-estimate"
        }
        s.powerMode = powerMode

        recent.append(s)
        if recent.count > 5 { recent.removeFirst() }
        s.findings = Analyzer.analyze(recent: recent, lowPower: powerMode == .low)
        last = s
        return s
    }

    func allSensors() -> [SensorReading] { catalog.read() }
}

struct HistoryPoint: Identifiable {
    let id: Date
    let cpu: Double, gpu: Double
    let cpuW: Double, gpuW: Double, otherW: Double
    let pTemp: Double?, eTemp: Double?, gpuTemp: Double?, socTemp: Double?
    let pFreq: Double, eFreq: Double
    let memUsed: Double, memCompressed: Double, swapUsed: Double   // GB
    let inputW: Double, batteryW: Double, portsOutW: Double
}

@Observable
final class Monitor {
    /// Live data for the menu bar and floating window (always updated).
    private(set) var snapshot = Snapshot()
    /// Dashboard copy: only updated while the dashboard window is visible, so a closed or
    /// hidden dashboard (SwiftUI keeps it alive) costs nothing to redraw.
    private(set) var dashboard = Snapshot()
    private(set) var history: [HistoryPoint] = []
    /// Menu bar text; only reassigned when it changes so the status item isn't re-rendered every tick.
    private(set) var menuBarText = "—"
    private(set) var menuBarHot = false
    private(set) var powerState = PowerModeControl.State.unknown
    private(set) var hardware: HardwareInfo?
    private(set) var allSensors: [SensorReading] = []
    var interval: Double = 2
    @ObservationIgnored private var historyBuffer: [HistoryPoint] = []
    /// Observed mirror of `dashboardVisible`; the dashboard drops its view tree when false.
    private(set) var dashboardActive = false
    @ObservationIgnored var dashboardVisible = false {
        didSet {
            guard dashboardVisible != oldValue else { return }
            if dashboardVisible { dashboard = snapshot; history = historyBuffer }
            dashboardActive = dashboardVisible
        }
    }
    /// The full sensor list is only scanned while someone is looking at it.
    @ObservationIgnored var wantsAllSensors = false
    /// Per-process network (nettop) only runs while the network tab is shown.
    @ObservationIgnored var wantsNetwork = false

    var findings: [Finding] { dashboard.findings }

    static let historyLength = 120

    @ObservationIgnored private let queue = DispatchQueue(label: "perfmonitor.sampler", qos: .utility)
    @ObservationIgnored private var timer: DispatchSourceTimer?
    @ObservationIgnored private var engine: Engine!
    @ObservationIgnored private var tick = 0
    /// Latest snapshot for the HTTP API, readable from any thread.
    @ObservationIgnored private let lock = NSLock()
    @ObservationIgnored private var latest = Snapshot()

    init() {
        queue.async { [self] in
            engine = Engine()
            let hw = HardwareInfo.gather(io: engine.io)
            DispatchQueue.main.async { self.hardware = hw }
        }
        refreshPowerState()
        start()
    }

    func start() {
        timer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: interval, leeway: .milliseconds(200))
        t.setEventHandler { [weak self] in self?.sampleOnce() }
        t.resume()
        timer = t
    }

    func setInterval(_ seconds: Double) {
        interval = seconds
        start()
    }

    func refreshPowerState() {
        queue.async {
            let s = PowerModeControl.read()
            self.engine?.powerMode = s.current
            DispatchQueue.main.async { self.powerState = s }
        }
    }

    func applyPowerMode(_ mode: PowerMode, sources: [PowerSource], completion: @escaping (String?) -> Void) {
        let supportsHigh = powerState.supportsHigh
        runPrivileged(completion) { PowerModeControl.apply(mode, sources: sources, supportsHigh: supportsHigh) }
    }

    func setPasswordless(_ on: Bool, completion: @escaping (String?) -> Void) {
        runPrivileged(completion) { on ? PowerModeControl.installPasswordless() : PowerModeControl.removePasswordless() }
    }

    private func runPrivileged(_ completion: @escaping (String?) -> Void, _ work: @escaping () -> String?) {
        DispatchQueue.global(qos: .userInitiated).async {
            let err = work()
            DispatchQueue.main.async {
                completion(err)
                self.refreshPowerState()
            }
        }
    }

    // MARK: - API access (any thread)

    func currentSnapshot() -> Snapshot {
        lock.lock(); defer { lock.unlock() }
        return latest
    }

    func currentSensors() -> [SensorReading] {
        var result: [SensorReading] = []
        queue.sync { result = engine?.allSensors() ?? [] }
        return result
    }

    func refreshHardware() {
        queue.async {
            let hw = HardwareInfo.gather(io: self.engine.io)
            DispatchQueue.main.async { self.hardware = hw }
        }
    }

    func currentHardware() -> HardwareInfo? {
        var hw: HardwareInfo?
        if Thread.isMainThread { return hardware }
        DispatchQueue.main.sync { hw = hardware }
        return hw
    }

    private func sampleOnce() {
        guard let engine else { return }
        engine.lightMode = !dashboardVisible
        engine.networkEnabled = wantsNetwork && dashboardVisible
        let s = engine.sample()
        lock.lock(); latest = s; lock.unlock()

        let point = HistoryPoint(
            id: s.time, cpu: s.system.cpuTotal, gpu: s.gpuUtil,
            cpuW: s.io.cpuW, gpuW: s.io.gpuW, otherW: max(0, s.totalW - s.io.cpuW - s.io.gpuW),
            pTemp: s.sensors.pCores?.avg, eTemp: s.sensors.eCores?.avg, gpuTemp: s.sensors.gpu?.avg, socTemp: s.socTemp,
            pFreq: s.io.pCluster.freqMHz, eFreq: s.io.eCluster.freqMHz,
            memUsed: s.system.memory.used / 1_073_741_824, memCompressed: s.system.memory.compressed / 1_073_741_824,
            swapUsed: s.system.memory.swapUsed / 1_073_741_824,
            inputW: s.power.onAC ? (s.power.systemInW ?? 0) : 0, batteryW: s.power.batteryW, portsOutW: s.power.portsOutW
        )
        tick += 1
        let refreshMode = tick % 60 == 0
        let sensors = wantsAllSensors && tick % 2 == 0 ? engine.allSensors() : nil

        DispatchQueue.main.async {
            self.snapshot = s
            let text = "\(s.socTemp.map { String(format: "%.0f°", $0) } ?? "—") \(String(format: "%.1fW", s.totalW))"
            if text != self.menuBarText { self.menuBarText = text }
            let hot = s.system.thermal >= .moderate
            if hot != self.menuBarHot { self.menuBarHot = hot }
            self.historyBuffer.append(point)
            if self.historyBuffer.count > Self.historyLength { self.historyBuffer.removeFirst(self.historyBuffer.count - Self.historyLength) }
            if self.dashboardVisible {
                self.dashboard = s
                self.history = self.historyBuffer
            }
            if let sensors { self.allSensors = sensors }
            if refreshMode { self.refreshPowerState() }
        }
    }
}
