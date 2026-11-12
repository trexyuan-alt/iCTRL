import Foundation
import Network

final class NonUIJSONRPCServer {
    private let queue = DispatchQueue(label: "com.openminis.ictrl.nonui.server")
    private var listener: NWListener?
    private var startedAt = Date()
    private(set) var isRunning = false
    let port: UInt16

    init(port: UInt16 = 8200) {
        self.port = port
    }

    func start() throws {
        guard listener == nil else { return }
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            throw NSError(domain: "NonUIJSONRPCServer", code: 1)
        }
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener = try NWListener(using: params, on: nwPort)
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.isRunning = true
                print("NON_UI_JSONRPC_READY port=\(self.port)")
            case .failed(let error):
                self.isRunning = false
                print("NON_UI_JSONRPC_FAILED \(error)")
            case .cancelled:
                self.isRunning = false
            default:
                break
            }
        }
        listener.newConnectionHandler = { [weak self] connection in
            self?.handle(connection)
        }
        self.listener = listener
        self.startedAt = Date()
        listener.start(queue: queue)
    }

    private func handle(_ connection: NWConnection) {
        connection.stateUpdateHandler = { [weak self, weak connection] state in
            guard let self, let connection else { return }
            if case .ready = state {
                self.receive(on: connection, buffer: Data())
            }
        }
        connection.start(queue: queue)
    }

    private func receive(on connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self else { return }
            var all = buffer
            if let data { all.append(data) }
            guard let text = String(data: all, encoding: .utf8),
                  let headerRange = text.range(of: "\r\n\r\n") else {
                if complete || error != nil { connection.cancel(); return }
                self.receive(on: connection, buffer: all)
                return
            }

            let header = String(text[..<headerRange.lowerBound])
            let bodyStart = text.distance(from: text.startIndex, to: headerRange.upperBound)
            var contentLength = 0
            for line in header.split(separator: "\r\n") {
                let parts = line.split(separator: ":", maxSplits: 1)
                if parts.count == 2 && parts[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length" {
                    contentLength = Int(parts[1].trimmingCharacters(in: .whitespaces)) ?? 0
                }
            }
            let availableBody = max(0, all.count - bodyStart)
            if availableBody < contentLength && !complete && error == nil {
                self.receive(on: connection, buffer: all)
                return
            }

            let requestLine = header.split(separator: "\r\n").first.map(String.init) ?? ""
            let bodyData = contentLength > 0 ? all.subdata(in: bodyStart..<(bodyStart + contentLength)) : Data()
            let response = self.response(requestLine: requestLine, body: bodyData)
            connection.send(content: response, completion: .contentProcessed { _ in connection.cancel() })
        }
    }

    private func response(requestLine: String, body: Data) -> Data {
        let uptime = Int(Date().timeIntervalSince(startedAt))
        var payload: [String: Any] = [
            "ok": true,
            "mode": "NON_UI_XCTRUNNER_LIFECYCLE_EXPERIMENT",
            "port": Int(port),
            "uptime_seconds": uptime,
            "pid": ProcessInfo.processInfo.processIdentifier
        ]

        if requestLine.hasPrefix("POST /rpc ") {
            if let obj = try? JSONSerialization.jsonObject(with: body) as? [String: Any] {
                let id = obj["id"] ?? NSNull()
                let method = obj["method"] as? String ?? ""
                if method == "status" || method == "ping" {
                    payload = ["jsonrpc": "2.0", "id": id, "result": payload]
                } else {
                    payload = ["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]]
                }
            }
        }

        let json = (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{}".utf8)
        var out = Data("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: \(json.count)\r\nConnection: close\r\n\r\n".utf8)
        out.append(json)
        return out
    }
}
