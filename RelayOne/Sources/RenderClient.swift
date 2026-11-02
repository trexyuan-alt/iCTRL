import Foundation

struct RenderEndpointCache: Decodable {
    let port: Int
    let identifier: String
    let authTag: String
    let wireProtocolVersion: String?
}

private struct RegisterRequest: Encodable {
    let backendIdentity: String
    let bundleID: String

    enum CodingKeys: String, CodingKey {
        case backendIdentity = "backend_identity"
        case bundleID = "bundle_id"
    }
}

private struct StateRequest: Encodable {
    let backendIdentity: String
    enum CodingKeys: String, CodingKey {
        case backendIdentity = "backend_identity"
    }
}

private struct StateResponse: Decodable {
    let ok: Bool
    let cache: RenderEndpointCache?
}

private struct PublishRequest: Encodable {
    let backendIdentity: String
    let observedAt: String
    let port: Int
    let identifier: String
    let authTag: String
    let wireProtocolVersion: String?

    enum CodingKeys: String, CodingKey {
        case backendIdentity = "backend_identity"
        case observedAt = "observed_at"
        case port
        case identifier
        case authTag
        case wireProtocolVersion
    }
}

private struct PublishResponse: Decodable {
    let ok: Bool
    let ack: Bool
    let changed: Bool
}

private struct RegisterResponse: Decodable {
    let ok: Bool
    let registered: Bool
}

enum RenderClientError: LocalizedError {
    case invalidResponse
    case rejected(Int)
    case backendRejected

    var errorDescription: String? {
        switch self {
        case .invalidResponse: return "Render returned an invalid response"
        case .rejected(let status): return "Render rejected the request (HTTP \(status))"
        case .backendRejected: return "Render did not acknowledge the endpoint update"
        }
    }
}

struct RenderClient {
    private let baseURL = URL(string: "https://iphone-coredevice-observation.onrender.com")!
    private let credentials: CompanionCredentials

    init(credentials: CompanionCredentials) {
        self.credentials = credentials
    }

    func register() async throws {
        let req = RegisterRequest(
            backendIdentity: credentials.identity,
            bundleID: Bundle.main.bundleIdentifier ?? "com.temporary.relayone"
        )
        let response: RegisterResponse = try await post("/coredevice/v1/companion/register", body: req)
        guard response.ok, response.registered else { throw RenderClientError.backendRejected }
    }

    func state() async throws -> RenderEndpointCache? {
        let req = StateRequest(backendIdentity: credentials.identity)
        let response: StateResponse = try await post("/coredevice/v1/companion/state", body: req)
        guard response.ok else { throw RenderClientError.backendRejected }
        return response.cache
    }

    func publish(_ endpoint: RemotePairingEndpoint) async throws {
        let req = PublishRequest(
            backendIdentity: credentials.identity,
            observedAt: ISO8601DateFormatter().string(from: Date()),
            port: endpoint.port,
            identifier: endpoint.identifier,
            authTag: endpoint.authTag,
            wireProtocolVersion: endpoint.wireProtocolVersion
        )
        let response: PublishResponse = try await post("/coredevice/v1/companion/publish", body: req)
        guard response.ok, response.ack else { throw RenderClientError.backendRejected }
    }

    private func post<Request: Encodable, Response: Decodable>(
        _ path: String,
        body: Request
    ) async throws -> Response {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw RenderClientError.invalidResponse
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(credentials.secret)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)

        let (data, response) = try await URLSession.shared.data(for: request)
        guard let http = response as? HTTPURLResponse else {
            throw RenderClientError.invalidResponse
        }
        guard (200...299).contains(http.statusCode) else {
            throw RenderClientError.rejected(http.statusCode)
        }
        return try JSONDecoder().decode(Response.self, from: data)
    }
}
