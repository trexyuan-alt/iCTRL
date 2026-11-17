import Foundation

/// Live status of the :8200 Companion surface, probed over HTTP.
///
/// Production hosts this surface in the normal iCTRL app with no XCTest UI
/// automation. The probe remains authoritative because it checks exactly what
/// the backend will reach rather than trusting local state.
@MainActor
final class RunnerStatus: ObservableObject {

    struct Info: Equatable {
        var serverVersion: String?
        var protocolVersion: Int?
        var capabilities: [String] = []
        var methodCount: Int?
    }

    enum State: Equatable {
        case unknown
        case checking
        case running(Info)
        case stopped
    }

    @Published private(set) var state: State = .unknown
    @Published private(set) var lastChecked: Date?

    private var pollTask: Task<Void, Never>?
    private let port: Int

    init(port: Int) { self.port = port }

    var isRunning: Bool { if case .running = state { return true }; return false }

    /// Poll while the view is on screen. The runner can be started or killed
    /// from outside this app (a URL scheme, a crash, iOS reclaiming it), so a
    /// one-shot check at appear would go stale while the user is looking at it.
    func startPolling(every seconds: TimeInterval = 3) {
        stopPolling()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                await self?.check()
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            }
        }
    }

    func stopPolling() {
        pollTask?.cancel()
        pollTask = nil
    }

    func check() async {
        if case .unknown = state { state = .checking }

        // Listener liveness is defined by the smallest stable public endpoint.
        // /whoami is the exact unauthenticated probe the production Gateway also
        // uses. /schema is metadata only: a schema-generation/decoding failure
        // must never make a live :8200 listener look stopped in the Companion UI.
        var healthRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/whoami")!)
        healthRequest.timeoutInterval = 2
        healthRequest.cachePolicy = .reloadIgnoringLocalCacheData

        do {
            let (healthData, healthResponse) = try await URLSession.shared.data(for: healthRequest)
            guard let http = healthResponse as? HTTPURLResponse, http.statusCode == 200,
                  let health = try? JSONSerialization.jsonObject(with: healthData) as? [String: Any] else {
                state = .stopped
                lastChecked = Date()
                return
            }

            var info = Info()
            info.serverVersion = health["server_version"] as? String
            info.protocolVersion = health["protocol_version"] as? Int

            // Best-effort presentation metadata. Failure here does not change
            // listener liveness already proven by /whoami.
            var schemaRequest = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/schema")!)
            schemaRequest.timeoutInterval = 2
            schemaRequest.cachePolicy = .reloadIgnoringLocalCacheData
            if let (schemaData, schemaResponse) = try? await URLSession.shared.data(for: schemaRequest),
               let schemaHTTP = schemaResponse as? HTTPURLResponse, schemaHTTP.statusCode == 200,
               let schema = try? JSONSerialization.jsonObject(with: schemaData) as? [String: Any] {
                info.serverVersion = info.serverVersion ?? schema["server_version"] as? String
                info.protocolVersion = info.protocolVersion ?? schema["protocol_version"] as? Int
                info.capabilities = schema["capability_tags"] as? [String] ?? []
                info.methodCount = (schema["methods"] as? [Any])?.count
            }

            state = .running(info)
        } catch {
            state = .stopped
        }
        lastChecked = Date()
    }
}
