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
        [
            "name": "start_tracking",
            "description": "开始在后台追踪某个应用（含它的所有 Helper 进程）或单个进程一段时间的性能占用：CPU、内存、CPU 能耗、GPU、磁盘和网络收发（每个子进程分别统计）。应用还没打开也可以先开始，打开后自动计入。返回记录 ID；之后用 get_tracking 查看。需要 PerfMonitor.app，未运行会自动在后台启动。",
            "inputSchema": ["type": "object", "required": ["target"], "properties": [
                "target": ["type": "string", "description": "应用名（如 ChatGPT、Google Chrome）、进程名、PID 或 .app 路径"],
                "minutes": ["type": "number", "description": "多少分钟后自动停止；省略则一直记录到 stop_tracking"],
                "network": ["type": "boolean", "description": "记录每个进程的网络收发，默认 true；设 false 可省一点开销"],
            ]],
        ],
        [
            "name": "stop_tracking",
            "description": "停止追踪并返回汇总。id 可以是记录 ID，也可以是应用名（停止该应用所有进行中的追踪）。",
            "inputSchema": ["type": "object", "required": ["id"], "properties": ["id": ["type": "string"]]],
        ],
        [
            "name": "list_trackings",
            "description": "全部性能追踪记录（进行中和已结束的），每条带一句话汇总、平均/峰值 CPU、内存、能耗及占整机比例。",
            "inputSchema": ["type": "object", "properties": [:] as [String: Any]],
        ],
        [
            "name": "get_tracking",
            "description": "一条追踪记录的详细汇总：时长、平均与峰值 CPU、占整机 CPU 比例、平均/峰值内存、CPU 能耗（J/Wh）与占整机能耗比例、GPU、磁盘读写、网络下载/上传与速率、各子进程分别用了多少（CPU/能耗/内存/GPU/磁盘/网络）。include_samples=true 时附带时间序列。",
            "inputSchema": ["type": "object", "required": ["id"], "properties": [
                "id": ["type": "string"],
                "include_samples": ["type": "boolean"],
            ]],
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
                    "serverInfo": ["name": "perfmonitor", "version": "1.7"],
                    "instructions": "本机（macOS）实时性能监控。想知道电脑现在卡不卡、哪里是瓶颈、多热、多耗电时，先调用 get_system_status。想知道某个应用一段时间里到底占用了多少资源，用 start_tracking / get_tracking。",
                ])
            case "ping":
                reply(id, result: [:])
            case "tools/list":
                reply(id, result: ["tools": tools])
            case "tools/call":
                let name = params["name"] as? String ?? ""
                let a = params["arguments"] as? [String: Any] ?? [:]
                let enc = { (s: String) in s.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&=+/"))) ?? s }
                var method = "GET"
                let path: String? = switch name {
                case "get_system_status": "/v1/status?top=\(a["top"] as? Int ?? 8)"
                case "get_top_processes":
                    "/v1/processes?sort=\(a["sort"] as? String ?? "cpu")&limit=\(a["limit"] as? Int ?? 15)&group=\((a["per_process"] as? Bool ?? false) ? "process" : "app")"
                case "get_sensors": "/v1/sensors"
                case "get_hardware_info": "/v1/hardware"
                case "start_tracking":
                    "/v1/tracks/start?target=\(enc(a["target"] as? String ?? ""))"
                        + ((a["minutes"] as? Double).map { "&minutes=\($0)" } ?? "")
                        + ((a["network"] as? Bool ?? true) ? "" : "&network=0")
                case "stop_tracking": "/v1/tracks/\(enc(a["id"] as? String ?? ""))/stop"
                case "list_trackings": "/v1/tracks"
                case "get_tracking": "/v1/tracks/\(enc(a["id"] as? String ?? ""))" + ((a["include_samples"] as? Bool ?? false) ? "?samples=1" : "")
                default: nil
                }
                if name == "start_tracking" || name == "stop_tracking" { method = "POST" }
                guard let path else { replyError(id, code: -32602, message: "unknown tool: \(name)"); continue }
                let (status, data) = Fetcher.request(method, path)
                let text = data.isEmpty ? "无法获取数据" : String(decoding: data, as: UTF8.self)
                reply(id, result: ["content": [["type": "text", "text": text]], "isError": status != 200])
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
