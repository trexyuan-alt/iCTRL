import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum PrewarmCanonicalState: String, Decodable, CaseIterable {
    case idle = "IDLE"
    case inFlight = "IN_FLIGHT"
    case warm = "WARM"
    case failed = "FAILED"
}

enum PrewarmProductError: LocalizedError {
    case configurationUnavailable
    case completionUnconfirmed
    case canonicalFailed
    var errorDescription: String? {
        switch self {
        case .configurationUnavailable: return "PREWARM configuration is unavailable."
        case .completionUnconfirmed: return "PREWARM terminal completion could not be factually confirmed."
        case .canonicalFailed: return "PREWARM reached canonical FAILED."
        }
    }
}

final class PrewarmNoRedirectDelegate: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

// Uses the existing owner-control-v2 Keychain authority read-only. No provision,
// rotate, ARM, service action, or credential is exposed to the Shortcut.
final class PrewarmClient {
    private let credential: OwnerControlCredential
    private let session: URLSession
    private let ownsSession: Bool

    init(credential: OwnerControlCredential, session: URLSession? = nil) {
        self.credential = credential
        self.ownsSession = session == nil
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            // The Gateway owns the 44s canonical terminal observer. Keep the
            // native request alive slightly beyond that bounded server window.
            config.timeoutIntervalForRequest = 46
            config.timeoutIntervalForResource = 48
            #if !os(Linux)
            config.waitsForConnectivity = false
            #endif
            self.session = URLSession(configuration: config, delegate: PrewarmNoRedirectDelegate(), delegateQueue: nil)
        }
    }

    static func fromKeychain() throws -> PrewarmClient {
        guard let credential = OwnerControlCredentialStore.load() else {
            throw PrewarmProductError.configurationUnavailable
        }
        return PrewarmClient(credential: credential)
    }

    func submit() async throws -> PrewarmCanonicalState {
        defer { if ownsSession { session.finishTasksAndInvalidate() } }
        guard let parts = URLComponents(string: credential.baseURL),
              parts.scheme == "https", let host = parts.host, !host.isEmpty,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              let base = parts.url, !credential.identity.isEmpty, credential.token.count == 64 else {
            throw PrewarmProductError.configurationUnavailable
        }
        let url = base.appendingPathComponent("owner").appendingPathComponent("v1").appendingPathComponent("prewarm")
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.identity, forHTTPHeaderField: "X-Owner-Identity")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw PrewarmProductError.completionUnconfirmed }
        guard let http = response as? HTTPURLResponse, http.statusCode == 200,
              data.count <= 16384,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: Self.resultKeys),
              let result = try? JSONDecoder().decode(Receipt.self, from: data), result.ok else {
            throw PrewarmProductError.completionUnconfirmed
        }
        // Gateway returns only after its canonical status observer sees a terminal
        // state. Never let an unexpected IDLE/IN_FLIGHT response look READY.
        switch result.prewarmState {
        case .warm:
            return .warm
        case .failed:
            throw PrewarmProductError.canonicalFailed
        case .idle, .inFlight:
            throw PrewarmProductError.completionUnconfirmed
        }
    }

    private struct Receipt: Decodable {
        let ok: Bool
        let prewarmState: PrewarmCanonicalState
        let joined: Bool
        enum CodingKeys: String, CodingKey {
            case ok, prewarmState = "prewarm_state", joined = "joined_by_user_request"
        }
    }
    private static let resultKeys: Set<String> = [
        "ok", "accepted", "collapsed", "prewarm_state", "joined_by_user_request",
        "trigger_timestamp", "bootstrap_started_timestamp", "bootstrap_completed_timestamp",
        "duration_ms", "session_reused", "session_bootstrapped", "error_type", "failure_stage"
    ]
}

// Shared by native intent execution and the zero-phone unit harness.
enum PrewarmIntentOperation {
    static func perform(submit: () async throws -> PrewarmCanonicalState) async throws -> String {
        let state = try await submit()
        switch state {
        case .warm: return state.rawValue
        case .failed: throw PrewarmProductError.canonicalFailed
        case .idle, .inFlight: throw PrewarmProductError.completionUnconfirmed
        }
    }
}
