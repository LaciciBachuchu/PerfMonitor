import Foundation

/// Model Context Protocol server over stdio (newline-delimited JSON-RPC 2.0).
/// Read-only tools; nothing here changes system state.
enum MCPServer {
    private static let tools: [[String: Any]] = [
        [
            "name": "get_system_status",
            "description": "Mac 当前整体状态：一句话摘要、瓶颈诊断（是否撞温度墙、CPU/GPU/内存/磁盘瓶颈）、CPU/GPU 占用与频率、各部件温度、热压力、内存压力与换页、整机/CPU/GPU 功耗、充电与接口对外供电、电池，以及占用最高的应用。先调用这个。",
            "inputSchema": ["type": "object", "properties": ["top": ["type": "integer", "description": "返回多少个最忙的应用，默认 8"]]],
        ],
        [
            "name": "get_top_processes",
            "description": "按 CPU、功耗、内存或磁盘 I/O 排序的进程/应用列表。",
            "inputSchema": ["type": "object", "properties": [
                "sort": ["type": "string", "enum": ["cpu", "power", "memory", "disk"]],
                "limit": ["type": "integer"],
                "per_process": ["type": "boolean", "description": "true 时不按应用合并 Helper 进程"],
            ]],
        ],
        [
            "name": "get_sensors",
            "description": "全部温度与电源传感器（SMC + HID），含分组、中文标注与原始键名。",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ],
        [
            "name": "get_hardware_info",
            "description": "硬件信息：机型、芯片、CPU/GPU 核心与最高频率、内存、存储、显示器（当前/最高分辨率与刷新率）、充电规格。",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ],
    ]

    static func run() -> Never {
        setvbuf(stdout, nil, _IOLBF, 0)
        while let line = readLine(strippingNewline: true) {
            guard !line.isEmpty,
                  let msg = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  let method = msg["method"] as? String else { continue }
            let id = msg["id"]
            let params = msg["params"] as? [String: Any] ?? [:]
            guard id != nil else { continue }   // notifications need no reply

            switch method {
            case "initialize":
                reply(id, result: [
                    "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                    "capabilities": ["tools": [:] as [String: Any]],
                    "serverInfo": ["name": "perfmonitor", "version": "1.1"],
                    "instructions": "本机（macOS）实时性能监控。想知道电脑现在卡不卡、哪里是瓶颈、多热、多耗电时，先调用 get_system_status。",
                ])
            case "ping":
                reply(id, result: [:])
            case "tools/list":
                reply(id, result: ["tools": tools])
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let a = params["arguments"] as? [String: Any] ?? [:]
                let path: String? = switch name {
                case "get_system_status": "/v1/status?top=\(a["top"] as? Int ?? 8)"
                case "get_top_processes":
                    "/v1/processes?sort=\(a["sort"] as? String ?? "cpu")&limit=\(a["limit"] as? Int ?? 15)&group=\((a["per_process"] as? Bool ?? false) ? "process" : "app")"
                case "get_sensors": "/v1/sensors"
                case "get_hardware_info": "/v1/hardware"
                default: nil
                }
                guard let path else { replyError(id, code: -32602, message: "unknown tool: \(name)"); continue }
                if let data = Fetcher.get(path) {
                    reply(id, result: ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]], "isError": false])
                } else {
                    reply(id, result: ["content": [["type": "text", "text": "无法获取数据"]], "isError": true])
                }
            default:
                replyError(id, code: -32601, message: "method not found: \(method)")
            }
        }
        exit(0)
    }

    private static func reply(_ id: Any?, result: [String: Any]) {
        write(["jsonrpc": "2.0", "id": id ?? NSNull(), "result": result])
    }

    private static func replyError(_ id: Any?, code: Int, message: String) {
        write(["jsonrpc": "2.0", "id": id ?? NSNull(), "error": ["code": code, "message": message]])
    }

    private static func write(_ obj: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: obj, options: [.withoutEscapingSlashes]) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }
}
