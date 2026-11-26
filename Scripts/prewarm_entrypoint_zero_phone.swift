import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

@main struct PrewarmZeroPhoneTests {
    static func main() async throws {
        let credential = OwnerControlCredential(baseURL: "https://gateway.invalid", identity: "ictrl-owner-test", token: String(repeating: "a", count: 64), createdAt: Date())
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [PrewarmMockProtocol.self]
        let session = URLSession(configuration: config, delegate: PrewarmNoRedirectDelegate(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        PrewarmMockProtocol.status = 200
		PrewarmMockProtocol.statusSequence = [202, 503]
		PrewarmMockProtocol.sequence = ["{\"ok\":true,\"prewarm_state\":\"IN_FLIGHT\",\"joined_by_user_request\":false,\"trigger_timestamp\":\"2026-11-26T00:00:00Z\"}", "{\"ok\":false,\"error\":\"OWNER_VERIFIER_UNAVAILABLE\"}"]
		PrewarmMockProtocol.requests = []
		do { _ = try await PrewarmClient(credential: credential, session: session).submit(); fatalError("accepted operation status failure accepted") }
		catch PrewarmProductError.completionUnconfirmed {}
		catch { fatalError("accepted operation was relabeled as admission failure") }
		precondition(PrewarmMockProtocol.requests == ["POST", "GET"])
		print("PASS verifier unavailable / admission rejection / no-ack uncertainty / accepted terminal uncertainty are distinct; no retry or recovery")
        PrewarmMockProtocol.calls = 0
        PrewarmMockProtocol.body = "{\"ok\":true,\"accepted\":true,\"prewarm_state\":\"WARM\",\"joined_by_user_request\":false,\"error_type\":\"RAW_SECRET\"}"
        let warm = try await PrewarmIntentOperation.perform { try await PrewarmClient(credential: credential, session: session).submit() }
        precondition(warm == "WARM" && !warm.contains("SECRET"))
        precondition(PrewarmMockProtocol.calls == 1)

        // Virtual monotonic time: exercise long/cold behavior without sleeping
        // or ever reaching a network/device. Every mock rejects other routes.
        for item in [
            ("first-status-warm", ["WARM"], 0.2, "WARM", 0),
            ("multiple-status-warm", ["IN_FLIGHT", "IN_FLIGHT", "WARM"], 0.2, "WARM", 0),
            ("factual-failed", ["FAILED"], 0.2, "FAILED", 0),
            ("long-warm", ["IN_FLIGHT", "IN_FLIGHT", "WARM"], 25.0, "WARM", 1),
            ("long-failed", ["IN_FLIGHT", "IN_FLIGHT", "FAILED"], 25.0, "FAILED", 1),
            ("warm-at-threshold", ["IN_FLIGHT", "WARM"], 25.0, "WARM", 0),
            ("deadline", ["IN_FLIGHT"], 48.0, "UNKNOWN", 0),
            ("declined-continuation", ["IN_FLIGHT", "IN_FLIGHT"], 25.0, "UNKNOWN", 1),
            ("status-transport", [], 0.2, "UNKNOWN", 0),
            ("operation-changed", ["WARM"], 0.2, "UNKNOWN", 0)
        ] {
            var time = 0.0, pauses = 0, foregrounds = 0
            func receipt(_ state: String, operation: String = "2026-11-26T00:00:00Z") -> String {
                "{\"ok\":true,\"prewarm_state\":\"\(state)\",\"joined_by_user_request\":false,\"trigger_timestamp\":\"\(operation)\"}"
            }
            PrewarmMockProtocol.calls = 0; PrewarmMockProtocol.requests = []
            PrewarmMockProtocol.sequence = [receipt("IN_FLIGHT")] + item.1.map { receipt($0) }
            if item.0 == "operation-changed" { PrewarmMockProtocol.sequence[1] = receipt("WARM", operation: "2026-11-26T00:00:01Z") }
            PrewarmMockProtocol.statusError = item.0 == "status-transport" ? URLError(.timedOut) : nil
            var result = "UNKNOWN"
            do {
                result = try await PrewarmIntentOperation.perform {
                    try await PrewarmClient(credential: credential, session: session, now: { time }, pause: { ns in
                        precondition(ns > 0 && ns <= PrewarmClient.observationInterval)
                        pauses += 1; time += item.2
                    }).submit {
                        precondition(time >= 25 && time < 48 && PrewarmMockProtocol.requests.last == "GET")
                        foregrounds += 1
                        if item.0 == "declined-continuation" { throw NSError(domain: "RAW_SECRET", code: 1) }
                    }
                }
            } catch {
                precondition(error is PrewarmProductError && !error.localizedDescription.contains("SECRET"))
                if error.localizedDescription.contains("FAILED") { result = "FAILED" }
            }
            precondition(result == item.3 && foregrounds == item.4, item.0)
            precondition(PrewarmMockProtocol.requests.filter { $0 == "POST" }.count == 1)
            precondition(PrewarmMockProtocol.requests.dropFirst().allSatisfy { $0 == "GET" })
            if item.0 == "first-status-warm" { precondition(pauses == 0) }
            print("PASS \(item.0): \(result), triggers=1, foregrounds=\(foregrounds)")
        }
        PrewarmMockProtocol.statusError = nil; PrewarmMockProtocol.sequence = []

        for entry in [(503, "OWNER_VERIFIER_UNAVAILABLE", "verifier"), (403, "RAW_SECRET", "rejected"), (502, "RAW_SECRET", "unconfirmed")] {
            PrewarmMockProtocol.status = entry.0; PrewarmMockProtocol.calls = 0; PrewarmMockProtocol.requests = []
            PrewarmMockProtocol.body = "{\"ok\":false,\"error\":\"\(entry.1)\"}"
            do { _ = try await PrewarmClient(credential: credential, session: session).submit(); fatalError("admission failure accepted") }
            catch {
                guard let error = error as? PrewarmProductError else { fatalError("raw admission error") }
                switch (entry.2,error) {
                case ("verifier",.verifierUnavailable), ("rejected",.admissionFailed), ("unconfirmed",.admissionUnconfirmed): break
                default: fatalError("admission and terminal semantics collapsed")
                }
                precondition(!error.localizedDescription.contains("SECRET") && !error.localizedDescription.contains("terminal"))
            }
            precondition(PrewarmMockProtocol.requests == ["POST"])
        }
        PrewarmMockProtocol.status = 200

        for state in [PrewarmCanonicalState.idle, .inFlight, .failed] {
            do { _ = try await PrewarmIntentOperation.perform { state }; fatalError("intent returned non-WARM success") }
            catch { precondition(error is PrewarmProductError) }
            PrewarmMockProtocol.calls = 0
            PrewarmMockProtocol.body = "{\"ok\":true,\"accepted\":true,\"prewarm_state\":\"\(state.rawValue)\",\"joined_by_user_request\":false}"
            do { _ = try await PrewarmClient(credential: credential, session: session).submit(); fatalError("non-success terminal result accepted as READY") }
            catch {
                precondition(error is PrewarmProductError)
                precondition(!error.localizedDescription.contains("SECRET"))
                if state == .failed { precondition(error.localizedDescription.contains("FAILED")) }
            }
            precondition(PrewarmMockProtocol.calls == 1)
        }

        for body in ["RAW_SECRET", "{}", "[]", "{\"ok\":true,\"prewarm_state\":\"READY\",\"joined_by_user_request\":false}", "{\"ok\":true,\"prewarm_state\":\"WARM\",\"joined_by_user_request\":false,\"token\":\"RAW_SECRET\"}"] {
            PrewarmMockProtocol.calls = 0; PrewarmMockProtocol.body = body
            do { _ = try await PrewarmClient(credential: credential, session: session).submit(); fatalError("invalid result accepted") }
            catch { precondition(!error.localizedDescription.contains("SECRET")) }
            precondition(PrewarmMockProtocol.calls == 1)
        }
        let transportErrors: [Error] = [URLError(.timedOut), URLError(.cannotConnectToHost), NSError(domain: "RAW_SECRET", code: 1)]
        for error in transportErrors {
            PrewarmMockProtocol.calls = 0; PrewarmMockProtocol.error = error
            do { _ = try await PrewarmClient(credential: credential, session: session).submit(); fatalError("transport failure accepted") }
            catch {
                precondition(error is PrewarmProductError)
                precondition(!error.localizedDescription.contains("SECRET") && !error.localizedDescription.contains("FAILED"))
            }
            precondition(PrewarmMockProtocol.calls == 1)
        }
        PrewarmMockProtocol.error = nil; PrewarmMockProtocol.status = 503; PrewarmMockProtocol.calls = 0
        do { _ = try await PrewarmClient(credential: credential, session: session).submit(); fatalError("HTTP failure accepted") } catch {}
        precondition(PrewarmMockProtocol.calls == 1)
        var redirectAllowed = true
        let request = URLRequest(url: URL(string: "https://gateway.invalid/forbidden")!)
        let response = HTTPURLResponse(url: request.url!, statusCode: 307, httpVersion: nil, headerFields: [:])!
        PrewarmNoRedirectDelegate().urlSession(session, task: session.dataTask(with: request), willPerformHTTPRedirection: response, newRequest: request) { redirectAllowed = $0 != nil }
        precondition(!redirectAllowed)
        KeychainStore.data = nil
        do { _ = try PrewarmClient.fromKeychain(); fatalError("missing configuration accepted") } catch {}
        KeychainStore.data = try JSONEncoder().encode(credential)
        _ = try PrewarmClient.fromKeychain()
        precondition(KeychainStore.reads == 2 && KeychainStore.writes == 0)
        print("PASS WARM only succeeds; FAILED/IDLE/IN_FLIGHT stop; one request; malformed/error/timeout fail closed; no retry/redirect; existing Keychain load only")
        print("PHONE_OPERATION_COUNT=0 LIVE_PREWARM_COUNT=0")
    }
}
