import Foundation
import Network

/// Read-only JSON API on 127.0.0.1 only. One request per connection, GET only.
final class HTTPServer {
    private var listener: NWListener?
    private let queue = DispatchQueue(label: "perfmonitor.http")
    private weak var source: DataSource?

    init(source: DataSource) { self.source = source }

    func start(port: UInt16 = APIRouter.port) {
        let params = NWParameters.tcp
        params.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        params.allowLocalEndpointReuse = true
        guard let l = try? NWListener(using: params) else { return }
        l.newConnectionHandler = { [weak self] c in self?.handle(c) }
        l.start(queue: queue)
        listener = l
    }

    private func handle(_ c: NWConnection) {
        c.start(queue: queue)
        c.receive(minimumIncompleteLength: 1, maximumLength: 16 * 1024) { [weak self] data, _, _, _ in
            guard let self, let data, let request = String(data: data, encoding: .utf8),
                  let line = request.split(separator: "\r\n", maxSplits: 1).first else { c.cancel(); return }
            let parts = line.split(separator: " ")
            var status = 405
            var body = JSON.encode(["error": "only GET is supported"])
            if parts.count >= 2, parts[0] == "GET", let source = self.source {
                // Sampling-dependent work (sensors) hops to the sampler queue; keep it off ours.
                DispatchQueue.global(qos: .utility).async {
                    let (st, b) = APIRouter.handle(path: String(parts[1]), source: source)
                    self.reply(c, status: st, body: b)
                }
                return
            }
            if parts.count >= 2, parts[0] == "OPTIONS" { status = 204; body = Data() }
            self.reply(c, status: status, body: body)
        }
    }

    private func reply(_ c: NWConnection, status: Int, body: Data) {
        let reason = [200: "OK", 204: "No Content", 404: "Not Found", 405: "Method Not Allowed", 503: "Service Unavailable"][status] ?? "OK"
        var head = "HTTP/1.1 \(status) \(reason)\r\n"
        head += "Content-Type: application/json; charset=utf-8\r\n"
        head += "Content-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n"
        c.send(content: Data(head.utf8) + body, completion: .contentProcessed { _ in c.cancel() })
    }
}
