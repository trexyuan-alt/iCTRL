import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum PrewarmCanonicalState: String, Decodable, CaseIterable {
    case idle = "IDLE", inFlight = "IN_FLIGHT", warm = "WARM", failed = "FAILED"
}

enum PrewarmProductError: LocalizedError {
    case configurationUnavailable, admissionFailed, admissionUnconfirmed, verifierUnavailable, completionUnconfirmed, canonicalFailed
    var errorDescription: String? {
        switch self {
        case .configurationUnavailable: return "PREWARM configuration is unavailable."
        case .admissionFailed: return "PREWARM admission was rejected before canonical acceptance."
        case .admissionUnconfirmed: return "PREWARM admission could not be confirmed; no canonical acceptance was observed."
        case .verifierUnavailable: return "PREWARM admission is blocked because the server Owner verifier is unavailable."
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

// Existing owner-control-v2 Keychain authority, loaded read-only. The canonical
// engine owns all PREWARM states; this client only observes its factual receipts.
final class PrewarmClient {
    // 40s canonical run + up to 3s trigger transport + 200ms poll interval
    // + up to 3s terminal transport, rounded to a bounded 48s total window.
    static let observationDeadline: TimeInterval = 48
    static let foregroundThreshold: TimeInterval = 25
    static let observationInterval: UInt64 = 200_000_000
    private let credential: OwnerControlCredential
    private let session: URLSession
    private let ownsSession: Bool
    private let now: () -> TimeInterval
    private let pause: (UInt64) async throws -> Void

    init(credential: OwnerControlCredential, session: URLSession? = nil,
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         pause: @escaping (UInt64) async throws -> Void = { try await Task.sleep(nanoseconds: $0) }) {
        self.credential = credential
        self.now = now
        self.pause = pause
        self.ownsSession = session == nil
        if let session { self.session = session }
        else {
            let config = URLSessionConfiguration.ephemeral
            config.timeoutIntervalForRequest = 3
            config.timeoutIntervalForResource = Self.observationDeadline
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

    func submit(continueInForeground: () async throws -> Void = { throw PrewarmProductError.completionUnconfirmed }) async throws -> PrewarmCanonicalState {
        defer { if ownsSession { session.finishTasksAndInvalidate() } }
        guard let parts = URLComponents(string: credential.baseURL),
              parts.scheme == "https", let host = parts.host, !host.isEmpty, parts.port != 8200,
              parts.user == nil, parts.password == nil, parts.query == nil, parts.fragment == nil,
              parts.path.isEmpty || parts.path == "/",
              let base = parts.url, !credential.identity.isEmpty, credential.token.count == 64 else {
            throw PrewarmProductError.configurationUnavailable
        }
        let started = now()
        // Exactly one trigger. All later network calls are authenticated GETs.
        let trigger = try await request(base: base, method: "POST", endpoint: "prewarm", status: 202, started: started)
        if trigger.prewarmState == .warm { return .warm }
        if trigger.prewarmState == .failed { throw PrewarmProductError.canonicalFailed }
        guard trigger.prewarmState == .inFlight, let operation = trigger.triggerTimestamp, !operation.isEmpty else {
            throw PrewarmProductError.completionUnconfirmed
        }
        var foregroundRequested = false
        while true {
            // Immediate first read; a terminal response never incurs a sleep.
            let status = try await request(base: base, method: "GET", endpoint: "prewarm-status", status: 200, started: started)
            guard status.triggerTimestamp == operation else { throw PrewarmProductError.completionUnconfirmed }
            switch status.prewarmState {
            case .warm: return .warm
            case .failed: throw PrewarmProductError.canonicalFailed
            case .idle: throw PrewarmProductError.completionUnconfirmed
            case .inFlight: break
            }
            guard now() - started < Self.observationDeadline, !Task.isCancelled else {
                throw PrewarmProductError.completionUnconfirmed
            }
            // Only a fresh same-operation IN_FLIGHT fact near the standard
            // 30s background limit can request continuation. Never retrigger.
            if !foregroundRequested && now() - started >= Self.foregroundThreshold {
                foregroundRequested = true
                do { try await continueInForeground() }
                catch { throw PrewarmProductError.completionUnconfirmed }
                continue // Immediately re-read canonical status after permission.
            }
            let remaining = Self.observationDeadline - (now() - started)
            guard remaining > 0 else { throw PrewarmProductError.completionUnconfirmed }
            do { try await pause(min(Self.observationInterval, UInt64(remaining * 1_000_000_000))) }
            catch { throw PrewarmProductError.completionUnconfirmed }
        }
    }

    private func request(base: URL, method: String, endpoint: String, status: Int, started: TimeInterval) async throws -> Receipt {
        let uncertain: PrewarmProductError = method == "POST" ? .admissionUnconfirmed : .completionUnconfirmed
        let remaining = Self.observationDeadline - (now() - started)
        guard remaining > 0, !Task.isCancelled else { throw uncertain }
        let url = base.appendingPathComponent("owner").appendingPathComponent("v1").appendingPathComponent(endpoint)
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.timeoutInterval = min(3, remaining)
        request.cachePolicy = .reloadIgnoringLocalCacheData
        request.setValue("Bearer \(credential.token)", forHTTPHeaderField: "Authorization")
        request.setValue(credential.identity, forHTTPHeaderField: "X-Owner-Identity")
        let data: Data
        let response: URLResponse
        do { (data, response) = try await session.data(for: request) }
        catch { throw uncertain }
        if method == "POST", let http = response as? HTTPURLResponse, http.statusCode != status {
            if http.statusCode == 503, data.count <= 16384,
               let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               Set(object.keys) == Set(["ok", "error"]),
               let failure = try? JSONDecoder().decode(AdmissionFailure.self, from: data),
               !failure.ok, failure.error == "OWNER_VERIFIER_UNAVAILABLE" {
                throw PrewarmProductError.verifierUnavailable
            }
            if http.statusCode == 403 || http.statusCode == 400 { throw PrewarmProductError.admissionFailed }
            throw PrewarmProductError.admissionUnconfirmed
        }
        guard now() - started < Self.observationDeadline,
              let http = response as? HTTPURLResponse, http.statusCode == status, data.count <= 16384,
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              Set(object.keys).isSubset(of: Self.resultKeys),
              let result = try? JSONDecoder().decode(Receipt.self, from: data), result.ok else {
            throw uncertain
        }
        return result
    }

    private struct Receipt: Decodable {
        let ok: Bool
        let prewarmState: PrewarmCanonicalState
        let joined: Bool
        let triggerTimestamp: String?
        enum CodingKeys: String, CodingKey {
            case ok, prewarmState = "prewarm_state", joined = "joined_by_user_request", triggerTimestamp = "trigger_timestamp"
        }
    }
    private struct AdmissionFailure: Decodable { let ok: Bool; let error: String }
    private static let resultKeys: Set<String> = [
        "ok", "accepted", "collapsed", "prewarm_state", "joined_by_user_request",
        "trigger_timestamp", "bootstrap_started_timestamp", "bootstrap_completed_timestamp",
        "duration_ms", "session_reused", "session_bootstrapped", "error_type", "failure_stage"
    ]
}

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
