import Foundation

enum OwnerControlClientError: LocalizedError {
    case configurationUnavailable
    case endpointInvalid
    case transportFailed
    case rejected

    var errorDescription: String? {
        switch self {
        case .configurationUnavailable:
            return "Owner control OOB configuration is unavailable."
        case .endpointInvalid:
            return "RemotePairing endpoint snapshot is invalid."
        case .transportFailed:
            return "Owner control OOB request failed."
        case .rejected:
            return "Owner control OOB request was rejected."
        }
    }
}

// Background V2: direct Companion-to-Observation authority transport.
final class OwnerControlClient {
    struct Configuration {
        let baseURL: URL
        let identity: String
        let token: String

        static func fromBundle(_ bundle: Bundle = .main) -> Configuration? {
            func value(_ key: String) -> String? {
                guard let raw = bundle.object(forInfoDictionaryKey: key) as? String else { return nil }
                let v = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !v.isEmpty, !v.contains("$(") else { return nil }
                return v
            }
            guard let base = value("ICTRLOwnerControlBaseURL"),
                  let url = URL(string: base),
                  url.scheme == "https",
                  url.host != nil,
                  let identity = value("ICTRLOwnerControlIdentity"),
                  identity.count >= 8,
                  let token = value("ICTRLOwnerControlToken"),
                  token.count >= 20 else {
                return nil
            }
            return Configuration(baseURL: url, identity: identity, token: token)
        }
    }

    private let configuration: Configuration
    private let session: URLSession

    init(configuration: Configuration, session: URLSession? = nil) {
        self.configuration = configuration
        if let session {
            self.session = session
        } else {
            let cfg = URLSessionConfiguration.ephemeral
            cfg.timeoutIntervalForRequest = 5
            cfg.timeoutIntervalForResource = 7
            cfg.waitsForConnectivity = false
            self.session = URLSession(configuration: cfg)
        }
    }

    static func fromBundle() -> OwnerControlClient? {
        guard let configuration = Configuration.fromBundle() else { return nil }
        return OwnerControlClient(configuration: configuration)
    }

    func arm(endpoint: [String: JSONValue], completion: @escaping (Result<Void, Error>) -> Void) {
        guard let port = endpoint["port"]?.intValue,
              (1...65535).contains(port),
              let identifier = endpoint["identifier"]?.stringValue,
              !identifier.isEmpty,
              let authTag = endpoint["authTag"]?.stringValue,
              !authTag.isEmpty,
              endpoint["service_type"]?.stringValue == "_remotepairing._tcp.local." else {
            completion(.failure(OwnerControlClientError.endpointInvalid))
            return
        }

        var payload: [String: Any] = [
            "backend_identity": configuration.identity,
            "action": "arm",
            "observed_at": ISO8601DateFormatter().string(from: Date()),
            "port": port,
            "identifier": identifier,
            "authTag": authTag,
        ]
        if let wire = endpoint["wireProtocolVersion"]?.stringValue, !wire.isEmpty {
            payload["wireProtocolVersion"] = wire
        }
        send(payload: payload, completion: completion)
    }

    func off(completion: @escaping (Result<Void, Error>) -> Void) {
        send(payload: [
            "backend_identity": configuration.identity,
            "action": "off",
        ], completion: completion)
    }

    private func send(payload: [String: Any], completion: @escaping (Result<Void, Error>) -> Void) {
        let url = configuration.baseURL
            .appendingPathComponent("coredevice")
            .appendingPathComponent("v1")
            .appendingPathComponent("companion")
            .appendingPathComponent("authority")
        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            completion(.failure(OwnerControlClientError.transportFailed))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(configuration.token)", forHTTPHeaderField: "Authorization")
        request.cachePolicy = .reloadIgnoringLocalCacheData

        session.dataTask(with: request) { data, response, error in
            guard error == nil,
                  let http = response as? HTTPURLResponse,
                  let data,
                  http.statusCode == 200,
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  obj["ok"] as? Bool == true else {
                completion(.failure(error == nil ? OwnerControlClientError.rejected : OwnerControlClientError.transportFailed))
                return
            }
            completion(.success(()))
        }.resume()
    }
}
