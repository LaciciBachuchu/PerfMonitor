import Foundation

/// macOS energy mode via pmset. Every Apple Silicon Mac has Low Power Mode;
/// some (14"/16" MacBook Pro with Max chips, etc.) also expose High Power Mode as `powermode 2`.
enum PowerMode: Int, CaseIterable, Identifiable {
    case low = 1, automatic = 0, high = 2
    var id: Int { rawValue }

    var label: String {
        switch self {
        case .low: "低功耗"
        case .automatic: "自动"
        case .high: "高性能"
        }
    }

    var detail: String {
        switch self {
        case .low: "限制 P 核频率、降低后台活动，更凉更省电"
        case .automatic: "系统默认调度"
        case .high: "允许更高持续功耗，风扇更积极"
        }
    }
}

enum PowerSource: String, CaseIterable, Identifiable {
    case battery = "-b", charger = "-c"
    var id: String { rawValue }
    var label: String {
        switch self {
        case .battery: "电池"
        case .charger: "电源"
        }
    }
}

enum PowerModeControl {
    struct State {
        /// Mode in effect right now (depends on whether the Mac is on battery).
        var current: PowerMode
        var battery: PowerMode
        var charger: PowerMode
        var supportsHigh: Bool
        /// The sudoers rule installed by `installPasswordless()` is present.
        var passwordless: Bool

        static let unknown = State(current: .automatic, battery: .automatic, charger: .automatic, supportsHigh: false, passwordless: false)

        func mode(for source: PowerSource) -> PowerMode { source == .battery ? battery : charger }
    }

    static let sudoersPath = "/etc/sudoers.d/perfmonitor"

    /// Reads both per-source settings and the active mode (no privileges needed).
    static func read() -> State {
        var s = State.unknown
        let caps = run("/usr/bin/pmset", ["-g", "cap"])
        s.supportsHigh = caps.split(whereSeparator: \.isWhitespace).contains("powermode")

        var section: PowerSource?
        for line in run("/usr/bin/pmset", ["-g", "custom"]).split(separator: "\n") {
            if line.hasPrefix("Battery Power") { section = .battery; continue }
            if line.hasPrefix("AC Power") { section = .charger; continue }
            guard let section, let mode = parse(line, supportsHigh: s.supportsHigh) else { continue }
            if section == .battery { s.battery = mode } else { s.charger = mode }
        }
        for line in run("/usr/bin/pmset", ["-g"]).split(separator: "\n") {
            if let mode = parse(line, supportsHigh: s.supportsHigh) { s.current = mode }
        }
        s.passwordless = run("/usr/bin/sudo", ["-n", "-l", "/usr/bin/pmset", "-b", "lowpowermode", "0"], status: true) == "0"
        return s
    }

    private static func parse(_ line: Substring, supportsHigh: Bool) -> PowerMode? {
        let parts = line.split(whereSeparator: \.isWhitespace)
        guard parts.count >= 2, let v = Int(parts[1]) else { return nil }
        if supportsHigh, parts[0] == "powermode" { return PowerMode(rawValue: v) }
        if !supportsHigh, parts[0] == "lowpowermode" { return v == 1 ? .low : .automatic }
        return nil
    }

    private static func pmsetArgs(_ mode: PowerMode, _ source: PowerSource, supportsHigh: Bool) -> [String] {
        supportsHigh
            ? [source.rawValue, "powermode", "\(mode.rawValue)"]
            : [source.rawValue, "lowpowermode", mode == .low ? "1" : "0"]
    }

    /// Applies a mode for the given power sources. Uses the passwordless sudo rule when
    /// installed; otherwise macOS shows its administrator password dialog.
    /// With `installPasswordless`, the sudoers rule is installed in the same password prompt.
    static func apply(_ mode: PowerMode, sources: [PowerSource], supportsHigh: Bool, installPasswordless: Bool = false) -> String? {
        let commands = sources.map { pmsetArgs(mode, $0, supportsHigh: supportsHigh) }
        if commands.allSatisfy({ run("/usr/bin/sudo", ["-n", "/usr/bin/pmset"] + $0, status: true) == "0" }) { return nil }
        var shell = commands.map { "/usr/bin/pmset " + $0.joined(separator: " ") }.joined(separator: " && ")
        var prompt = "性能监控要切换性能档位（\(mode.label)）。"
        var cleanup: URL?
        if installPasswordless {
            switch passwordlessCommand() {
            case .success(let (cmd, tmp)):
                shell += " && " + cmd
                cleanup = tmp
                prompt += "并开启免密码切换：以后不再需要输入密码（仅限 pmset 低功耗/性能模式命令）。"
            case .failure(let err):
                return err.message
            }
        }
        defer { if let cleanup { try? FileManager.default.removeItem(at: cleanup) } }
        return admin(shell, prompt: prompt)
    }

    private struct Failure: Error { let message: String }

    /// Shell command that validates and installs the sudoers rule, plus the temp file it reads.
    private static func passwordlessCommand() -> Result<(String, URL), Failure> {
        let user = NSUserName()
        guard user.range(of: #"^[A-Za-z0-9._-]+$"#, options: .regularExpression) != nil else { return .failure(Failure(message: "用户名包含不支持的字符")) }
        var allowed: [String] = []
        for source in ["-a", "-b", "-c"] {
            allowed += ["0", "1"].map { "/usr/bin/pmset \(source) lowpowermode \($0)" }
            allowed += ["0", "1", "2"].map { "/usr/bin/pmset \(source) powermode \($0)" }
        }
        let rule = "# Installed by PerfMonitor: switch energy mode without a password.\n"
            + "\(user) ALL=(root) NOPASSWD: " + allowed.joined(separator: ", ") + "\n"
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("perfmonitor-sudoers-\(UUID().uuidString)")
        do { try rule.write(to: tmp, atomically: true, encoding: .utf8) } catch { return .failure(Failure(message: error.localizedDescription)) }
        return .success(("/usr/sbin/visudo -cf '\(tmp.path)' && /usr/bin/install -m 0440 -o root -g wheel '\(tmp.path)' \(sudoersPath)", tmp))
    }

    /// Installs a sudoers rule that lets *this user* run exactly the pmset commands above
    /// without a password. Asks for the admin password once; validated with visudo first.
    static func installPasswordless() -> String? {
        switch passwordlessCommand() {
        case .success(let (cmd, tmp)):
            defer { try? FileManager.default.removeItem(at: tmp) }
            return admin(cmd, prompt: "性能监控要添加一条规则：以后切换性能档位不再需要输入密码（仅限 pmset 低功耗/性能模式命令）。")
        case .failure(let err):
            return err.message
        }
    }

    static func removePasswordless() -> String? {
        admin("/bin/rm -f \(sudoersPath)", prompt: "性能监控要移除免密码切换性能档位的规则。")
    }

    /// Runs a shell command as root through the standard macOS authorization dialog.
    /// osascript runs as a child process because NSAppleScript is main-thread only.
    private static func admin(_ shell: String, prompt: String) -> String? {
        let escaped = shell.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
        let script = "do shell script \"\(escaped)\" with prompt \"\(prompt)\" with administrator privileges"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", script]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { return error.localizedDescription }
        p.waitUntilExit()
        guard p.terminationStatus != 0 else { return nil }
        let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        if msg.contains("-128") { return "已取消" }
        return msg.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs a command; returns stdout, or the exit status as a string when `status` is true.
    private static func run(_ path: String, _ args: [String], status: Bool = false) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: path)
        p.arguments = args
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return status ? "-1" : "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return status ? "\(p.terminationStatus)" : String(decoding: data, as: UTF8.self)
    }
}
