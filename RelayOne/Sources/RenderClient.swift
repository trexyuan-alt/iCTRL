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

private final class HTTPMetricsCollector: NSObject, URLSessionTaskDelegate {
    private let lock = NSLock()
    private var collected: URLSessionTaskMetrics?

    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didFinishCollecting metrics: URLSessionTaskMetrics
    ) {
        lock.lock()
        collected = metrics
        lock.unlock()
    }

    func summary() -> String {
        lock.lock()
        let metrics = collected
        lock.unlock()

        guard let tx = metrics?.transactionMetrics.last else {
            return "metrics=unavailable"
        }

        func ms(_ start: Date?, _ end: Date?) -> String {
            guard let start, let end else { return "na" }
            let value = max(0, Int((end.timeIntervalSince(start) * 1000).rounded()))
            return String(value)
        }

        return [
            "dns_ms=\(ms(tx.domainLookupStartDate, tx.domainLookupEndDate))",
            "connect_ms=\(ms(tx.connectStartDate, tx.connectEndDate))",
            "tls_ms=\(ms(tx.secureConnectionStartDate, tx.secureConnectionEndDate))",
            "ttfb_ms=\(ms(tx.requestStartDate, tx.responseStartDate))",
            "response_ms=\(ms(tx.responseStartDate, tx.responseEndDate))",
        ].joined(separator: " ")
    }
}

enum RenderClientError: LocalizedError {
    case invalidResponse(stage: String, metrics: String)
    case rejected(stage: String, status: Int, metrics: String)
    case backendRejected(stage: String)
    case transport(stage: String, code: Int, description: String, metrics: String)
    case decode(stage: String, description: String, metrics: String)

    var errorDescription: String? {
        switch self {
        case .invalidResponse(let stage, let metrics):
            return "[\(stage)] Render returned an invalid response; \(metrics)"
        case .rejected(let stage, let status, let metrics):
            return "[\(stage)] Render rejected the request (HTTP \(status)); \(metrics)"
        case .backendRejected(let stage):
            return "[\(stage)] Render did not acknowledge the endpoint request"
        case .transport(let stage, let code, let description, let metrics):
            return "[\(stage)] URLSession failed (URLError \(code): \(description)); \(metrics)"
        case .decode(let stage, let description, let metrics):
            return "[\(stage)] Render response decode failed (\(description)); \(metrics)"
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
        let response: RegisterResponse = try await post(
            stage: "REGISTER",
            path: "/coredevice/v1/companion/register",
            body: req
        )
        guard response.ok, response.registered else {
            throw RenderClientError.backendRejected(stage: "REGISTER")
        }
    }

    func state() async throws -> RenderEndpointCache? {
        let req = StateRequest(backendIdentity: credentials.identity)
        let response: StateResponse = try await post(
            stage: "STATE",
            path: "/coredevice/v1/companion/state",
            body: req
        )
        guard response.ok else {
            throw RenderClientError.backendRejected(stage: "STATE")
        }
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
        let response: PublishResponse = try await post(
            stage: "PUBLISH",
            path: "/coredevice/v1/companion/publish",
            body: req
        )
        guard response.ok, response.ack else {
            throw RenderClientError.backendRejected(stage: "PUBLISH")
        }
    }

    private func post<Request: Encodable, Response: Decodable>(
        stage: String,
        path: String,
        body: Request
    ) async throws -> Response {
        guard let url = URL(string: path, relativeTo: baseURL) else {
            throw RenderClientError.invalidResponse(stage: stage, metrics: "metrics=not_started")
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(credentials.secret)", forHTTPHeaderField: "Authorization")
        request.httpBody = try JSONEncoder().encode(body)

        let configuration = URLSessionConfiguration.ephemeral
        configuration.waitsForConnectivity = false
        configuration.timeoutIntervalForRequest = 10
        configuration.timeoutIntervalForResource = 15
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData

        let metrics = HTTPMetricsCollector()
        let session = URLSession(
            configuration: configuration,
            delegate: metrics,
            delegateQueue: nil
        )
        defer { session.finishTasksAndInvalidate() }

        do {
            let (data, response) = try await session.data(for: request)
            let metricSummary = metrics.summary()

            guard let http = response as? HTTPURLResponse else {
                throw RenderClientError.invalidResponse(stage: stage, metrics: metricSummary)
            }
            guard (200...299).contains(http.statusCode) else {
                throw RenderClientError.rejected(
                    stage: stage,
                    status: http.statusCode,
                    metrics: metricSummary
                )
            }

            do {
                return try JSONDecoder().decode(Response.self, from: data)
            } catch {
                throw RenderClientError.decode(
                    stage: stage,
                    description: error.localizedDescription,
                    metrics: metricSummary
                )
            }
        } catch let error as RenderClientError {
            throw error
        } catch let error as URLError {
            throw RenderClientError.transport(
                stage: stage,
                code: error.code.rawValue,
                description: error.localizedDescription,
                metrics: metrics.summary()
            )
        } catch {
            throw RenderClientError.transport(
                stage: stage,
                code: -1,
                description: error.localizedDescription,
                metrics: metrics.summary()
            )
        }
    }
}
