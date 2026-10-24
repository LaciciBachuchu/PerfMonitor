import Darwin
import Foundation
import Security

/// On-demand details for the process inspector (not sampled every tick).
enum ProcessDetails {
    struct FD: Identifiable {
        enum Kind: String { case file = "文件", socket = "网络", unix = "本地套接字", pipe = "管道", other = "其他" }
        let id: Int32
        let kind: Kind
        let text: String
    }

    /// Open files, sockets and pipes. Only works for our own processes (EPERM otherwise).
    static func openFiles(_ pid: pid_t) -> [FD]? {
        let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
        guard bytes > 0 else { return nil }
        var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / MemoryLayout<proc_fdinfo>.stride)
        let got = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, &fds, bytes)
        guard got > 0 else { return nil }
        return fds.prefix(Int(got) / MemoryLayout<proc_fdinfo>.stride).map { fd in
            switch Int32(fd.proc_fdtype) {
            case Int32(PROX_FDTYPE_VNODE):
                var info = vnode_fdinfowithpath()
                let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
                if proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size {
                    let path = withUnsafeBytes(of: info.pvip.vip_path) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
                    return FD(id: fd.proc_fd, kind: .file, text: path)
                }
                return FD(id: fd.proc_fd, kind: .file, text: "（无法读取路径）")
            case Int32(PROX_FDTYPE_SOCKET):
                return socket(pid, fd.proc_fd)
            case Int32(PROX_FDTYPE_PIPE):
                return FD(id: fd.proc_fd, kind: .pipe, text: "管道")
            default:
                return FD(id: fd.proc_fd, kind: .other, text: fdTypeName(Int32(fd.proc_fdtype)))
            }
        }
    }

    private static func fdTypeName(_ t: Int32) -> String {
        switch t {
        case Int32(PROX_FDTYPE_KQUEUE): "kqueue"
        case Int32(PROX_FDTYPE_PSHM): "POSIX 共享内存"
        case Int32(PROX_FDTYPE_PSEM): "POSIX 信号量"
        case Int32(PROX_FDTYPE_NETPOLICY): "网络策略"
        case Int32(PROX_FDTYPE_CHANNEL): "通道"
        default: "类型 \(t)"
        }
    }

    private static func socket(_ pid: pid_t, _ fd: Int32) -> FD {
        var info = socket_fdinfo()
        let size = Int32(MemoryLayout<socket_fdinfo>.size)
        guard proc_pidfdinfo(pid, fd, PROC_PIDFDSOCKETINFO, &info, size) == size else {
            return FD(id: fd, kind: .socket, text: "套接字")
        }
        let si = info.psi
        switch Int32(si.soi_kind) {
        case Int32(SOCKINFO_TCP), Int32(SOCKINFO_IN):
            let ini = si.soi_kind == Int32(SOCKINFO_TCP) ? si.soi_proto.pri_tcp.tcpsi_ini : si.soi_proto.pri_in
            let v6 = ini.insi_vflag & UInt8(INI_IPV6) != 0
            let local = address(ini.insi_laddr, v6: v6) + ":" + "\(UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_lport)))"
            let fport = UInt16(bigEndian: UInt16(truncatingIfNeeded: ini.insi_fport))
            let remote = fport == 0 ? "" : " → " + address(ini.insi_faddr, v6: v6) + ":\(fport)"
            let proto = si.soi_kind == Int32(SOCKINFO_TCP) ? "TCP" : (si.soi_type == SOCK_DGRAM ? "UDP" : "IP")
            let state = si.soi_kind == Int32(SOCKINFO_TCP) ? " " + tcpState(si.soi_proto.pri_tcp.tcpsi_state) : ""
            return FD(id: fd, kind: .socket, text: "\(proto)\(v6 ? "6" : "") \(local)\(remote)\(state)")
        case Int32(SOCKINFO_UN):
            let path = withUnsafeBytes(of: si.soi_proto.pri_un.unsi_addr.ua_sun.sun_path) {
                String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
            }
            return FD(id: fd, kind: .unix, text: path.isEmpty ? "本地套接字" : path)
        default:
            return FD(id: fd, kind: .socket, text: "套接字（类型 \(si.soi_kind)）")
        }
    }

    private static func address(_ a: in_sockinfo.__Unnamed_union_insi_faddr, v6: Bool) -> String {
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if v6 {
            var addr = a.ina_6
            inet_ntop(AF_INET6, &addr, &buf, socklen_t(buf.count))
        } else {
            var addr = a.ina_46.i46a_addr4
            inet_ntop(AF_INET, &addr, &buf, socklen_t(buf.count))
        }
        let s = String(cString: buf)
        return s == "0.0.0.0" || s == "::" ? "*" : s
    }

    private static func address(_ a: in_sockinfo.__Unnamed_union_insi_laddr, v6: Bool) -> String {
        var buf = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
        if v6 {
            var addr = a.ina_6
            inet_ntop(AF_INET6, &addr, &buf, socklen_t(buf.count))
        } else {
            var addr = a.ina_46.i46a_addr4
            inet_ntop(AF_INET, &addr, &buf, socklen_t(buf.count))
        }
        let s = String(cString: buf)
        return s == "0.0.0.0" || s == "::" ? "*" : s
    }

    private static func tcpState(_ s: Int32) -> String {
        ["CLOSED", "LISTEN", "SYN_SENT", "SYN_RECEIVED", "ESTABLISHED", "CLOSE_WAIT", "FIN_WAIT_1",
         "CLOSING", "LAST_ACK", "FIN_WAIT_2", "TIME_WAIT"][safe: Int(s)] ?? "\(s)"
    }

    // MARK: - Code signing

    struct Signing {
        var identifier: String?
        var team: String?
        var apple = false
        var sandboxed = false
        var hardenedRuntime = false
        var valid = false
    }

    static func signing(_ path: String) -> Signing? {
        guard !path.isEmpty else { return nil }
        var code: SecStaticCode?
        let url = URL(fileURLWithPath: path) as CFURL
        guard SecStaticCodeCreateWithPath(url, [], &code) == errSecSuccess, let code else { return nil }
        var s = Signing()
        s.valid = SecStaticCodeCheckValidity(code, [], nil) == errSecSuccess
        var info: CFDictionary?
        if SecCodeCopySigningInformation(code, SecCSFlags(rawValue: kSecCSSigningInformation | kSecCSRequirementInformation), &info) == errSecSuccess,
           let dict = info as? [String: Any] {
            s.identifier = dict[kSecCodeInfoIdentifier as String] as? String
            s.team = dict[kSecCodeInfoTeamIdentifier as String] as? String
            let ent = dict[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
            s.sandboxed = ent?["com.apple.security.app-sandbox"] as? Bool ?? false
            let flags = (dict[kSecCodeInfoFlags as String] as? NSNumber)?.uint32Value ?? 0
            s.hardenedRuntime = flags & SecCodeSignatureFlags.runtime.rawValue != 0
        }
        var req: SecRequirement?
        if SecRequirementCreateWithString("anchor apple" as CFString, [], &req) == errSecSuccess, let req {
            s.apple = SecStaticCodeCheckValidity(code, [], req) == errSecSuccess
        }
        return s
    }

    // MARK: - Sample

    /// Runs /usr/bin/sample for a few seconds and returns its report (own processes only).
    static func sample(_ pid: pid_t, seconds: Int = 3) -> String {
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("perfmonitor-sample-\(pid)-\(UUID().uuidString).txt")
        defer { try? FileManager.default.removeItem(at: out) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        p.arguments = ["\(pid)", "\(seconds)", "-mayDie", "-file", out.path]
        let err = Pipe()
        p.standardError = err
        p.standardOutput = FileHandle.nullDevice
        do { try p.run() } catch { return "无法启动 sample：\(error.localizedDescription)" }
        p.waitUntilExit()
        if let text = try? String(contentsOf: out, encoding: .utf8), !text.isEmpty { return text }
        let msg = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        return "采样失败。\(msg.trimmingCharacters(in: .whitespacesAndNewlines))\n\n其他用户（如系统）的进程需要管理员权限才能采样。"
    }
}

extension Array {
    subscript(safe i: Int) -> Element? { indices.contains(i) ? self[i] : nil }
}
