import Foundation

enum OwnerControlClientError: LocalizedError {
    case configurationUnavailable
    case endpointInvalid
    case transportFailed
    case rejected
    case provisioningFailed

    var errorDescription: String? {
        switch self {
        case .configurationUnavailable:
            return "Owner control credential is not provisioned."
        case .endpointInvalid:
            return "RemotePairing endpoint snapshot is invalid."
        case .transportFailed:
            return "Owner control OOB request failed."
        case .rejected:
            return "Owner control OOB request was rejected."
        case .provisioningFailed:
            return "Owner control credential provisioning failed."
        }
    }
}

struct OwnerControlCredential: Codable {
    let baseURL: String
    let identity: String
    let token: String
    let createdAt: Date
}

enum OwnerControlCredentialStore {
    static let account = "owner-control-v2"

    static func load() -> OwnerControlCredential? {
        guard let data = KeychainStore.load(account: account) else { return nil }
        return try? JSONDecoder().decode(OwnerControlCredential.self, from: data)
    }

    @discardableResult
    static func rotate(baseURL raw: String) throws -> OwnerControlCredential {
        guard let url = URL(string: raw),
              url.scheme == "https",
              url.host != nil,
              url.user == nil,
              url.query == nil,
              url.fragment == nil else {
            throw OwnerControlClientError.provisioningFailed
        }
        guard let secret = SecureEnvelope.randomBytes(32) else {
            throw OwnerControlClientError.provisioningFailed
        }
        let credential = OwnerControlCredential(
            baseURL: url.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/")),
            identity: "ictrl-owner-" + UUID().uuidString.lowercased(),
            token: secret.hexString,
            createdAt: Date()
        )
        guard let data = try? JSONEncoder().encode(credential) else {
            throw OwnerControlClientError.provisioningFailed
        }
        KeychainStore.save(data, account: account)
        guard let verified = load(),
              verified.identity == credential.identity,
              verified.token == credential.token,
              verified.baseURL == credential.baseURL else {
            KeychainStore.clear(account: account)
            throw OwnerControlClientError.provisioningFailed
        }
        return credential
    }

    static func clear() {
        KeychainStore.clear(account: account)
    }
}

// Background V2: direct Companion-to-Observation authority transport.
final class OwnerControlClient {
    private let credential: OwnerControlCredential
    private let session: URLSession

    init(credential: OwnerControlCredential, session: URLSession? = nil) {
        self.credential = credential
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

    static func fromKeychain() -> OwnerControlClient? {
        guard let credential = OwnerControlCredentialStore.load() else { return nil }
        return OwnerControlClient(credential: credential)
    }

    func arm(completion: @escaping (Result<Void, Error>) -> Void) {
        send(payload: [
            "backend_identity": credential.identity,
            "action": "arm",
        ], completion: completion)
    }

    func off(completion: @escaping (Result<Void, Error>) -> Void) {
        send(payload: [
            "backend_identity": credential.identity,
            "action": "off",
        ], completion: completion)
    }

    private func send(payload: [String: Any], completion: @escaping (Result<Void, Error>) -> Void) {
        guard let base = URL(string: credential.baseURL) else {
            completion(.failure(OwnerControlClientError.configurationUnavailable))
            return
        }
        let url = base
            .appendingPathComponent("owner")
            .appendingPathComponent("v1")
            .appendingPathComponent("authority")
        guard let body = try? JSONSerialization.data(withJSONObject: payload, options: []) else {
            completion(.failure(OwnerControlClientError.transportFailed))
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
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
