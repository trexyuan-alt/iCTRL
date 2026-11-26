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
        PrewarmMockProtocol.calls = 0
        PrewarmMockProtocol.body = "{\"ok\":true,\"accepted\":true,\"prewarm_state\":\"WARM\",\"joined_by_user_request\":false,\"error_type\":\"RAW_SECRET\"}"
        let warm = try await PrewarmIntentOperation.perform { try await PrewarmClient(credential: credential, session: session).submit() }
        precondition(warm == "WARM" && !warm.contains("SECRET"))
        precondition(PrewarmMockProtocol.calls == 1)

        for state in [PrewarmCanonicalState.idle, .inFlight, .failed] {
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