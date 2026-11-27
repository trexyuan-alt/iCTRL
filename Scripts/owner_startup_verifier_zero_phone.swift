import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class StartupProtocol: URLProtocol {
    static var handler: ((StartupProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { DispatchQueue.main.async { Self.handler?(self) } }
    override func stopLoading() {}
    func reply(_ code: Int, _ body: String) {
        let response = HTTPURLResponse(url: request.url!, statusCode: code,
            httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    func timeout() { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)) }
}
func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError("FAIL: \(message)") }
}
func spin(_ predicate: () -> Bool) {
    let deadline = Date().addingTimeInterval(4)
    while !predicate() && Date() < deadline {
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005))
    }
    expect(predicate(), "bounded completion")
}
func observe(for seconds: TimeInterval) {
    let deadline = Date().addingTimeInterval(seconds)
    while Date() < deadline {
        _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
}
func makeClient() -> OwnerControlClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [StartupProtocol.self]
    return OwnerControlClient(credential: OwnerControlCredential(baseURL: "https://zero-phone.invalid",
        identity: "owner-test", token: String(repeating: "a", count: 64), createdAt: Date()),
        session: URLSession(configuration: config))
}
let armedBody = """
{"ok":true,"owner_armed":true,"authority_epoch":7,"armed_generation":3,"absolute_expires_at":"","control_state":"RUNNING","control_generation":3}
"""
let disarmedBody = """
{"ok":true,"owner_armed":false,"authority_epoch":8,"armed_generation":0,"absolute_expires_at":"","control_state":"STOPPED","control_generation":4}
"""
let missingBody = "{\"error\":\"owner verifier unavailable\",\"ok\":false}"
let armed = try! JSONDecoder().decode(OwnerAuthorityStatus.self, from: Data(armedBody.utf8))
var requests: [URLRequest] = []
func record(_ proto: StartupProtocol) {
    let req = proto.request
    requests.append(req)
    expect(req.value(forHTTPHeaderField: "Authorization") == "Bearer " + String(repeating: "a", count: 64), "authenticated request")
    if req.httpMethod == "GET" {
        expect(req.url?.path == "/owner/v1/authority", "only authority GET")
        expect(req.value(forHTTPHeaderField: "X-Owner-Identity") == "owner-test", "authenticated identity")
    } else {
        expect(req.url?.path == "/owner/v1/service", "no automatic ARM/PREWARM or fallback")
        let body = try! JSONSerialization.jsonObject(with: req.httpBody!) as! [String: Any]
        expect(body["action"] as? String == "start", "explicit START only")
    }
}

// Execute the actual init -> actual startServer -> fake listener-ready callback.
do {
    TestEnvironment.autoStart = true
    TestEnvironment.client = makeClient()
    requests = []; JSONRPCServer.starts = 0
    StartupProtocol.handler = { proto in record(proto); proto.reply(200, armedBody) }
    let app = AppState()
    spin { app.isServerRunning && app.ownerAuthorityState == .armed }
    expect(JSONRPCServer.starts == 1, "autoStartServer starts local :8200")
    expect(!app.serviceStartLifecyclePending, "automatic startup never creates Owner START intent")
    expect(requests.allSatisfy { $0.httpMethod == "GET" }, "automatic startup sends ZERO Owner START/ARM/PREWARM")
    print("PASS autoStartServer=true: actual init starts local listener; zero Owner lifecycle POSTs")

    requests = []
    app.startCompanionService()
    spin { !app.ownerControlBusy && !app.ownerAuthorityRefreshInFlight }
    expect(requests.filter { $0.httpMethod == "POST" }.count == 1, "explicit START sends exactly one lifecycle request")
    expect(!app.serviceStartLifecyclePending, "explicit intent consumed before I/O")
    JSONRPCServer.last?.onStateChange?(true)
    observe(for: 0.1)
    expect(requests.filter { $0.httpMethod == "POST" }.count == 1, "listener-ready callback cannot replay START")
    app.setApplicationActive(false); app.stopServer()
    print("PASS explicit user START preserved exactly once; no implicit replay")
}

do {
    TestEnvironment.autoStart = true
    TestEnvironment.client = makeClient()
    requests = []; JSONRPCServer.starts = 0
    StartupProtocol.handler = { proto in record(proto); proto.reply(503, missingBody) }
    let app = AppState()
    spin { app.isServerRunning && app.ownerAuthorityState == .verifierUnavailable }
    expect(JSONRPCServer.starts == 1 && !app.serviceStartLifecyclePending, "listener startup needs no Owner verifier")
    expect(requests.count == 1 && requests.allSatisfy { $0.httpMethod == "GET" }, "missing verifier cannot trigger Owner lifecycle or recovery")

    requests = []
    app.startCompanionService()
    spin { !app.ownerControlBusy && !app.ownerAuthorityRefreshInFlight }
    JSONRPCServer.last?.onStateChange?(true)
    observe(for: 0.1)
    expect(requests.filter { $0.httpMethod == "POST" }.count == 1, "failed explicit START is never retried")
    expect(app.isServerRunning && !app.serviceStartLifecyclePending, "failed Owner lifecycle does not stop local listener")
    app.setApplicationActive(false); app.stopServer()
    print("PASS missing verifier does not block local auto-start; failed explicit START is not retried")
}

do {
    requests = []; JSONRPCServer.starts = 0
    StartupProtocol.handler = { proto in record(proto); proto.reply(200, armedBody) }
    let app = AppState(client: makeClient(), initial: armed)
    app.autoStartServer = true
    app.setApplicationActive(true)
    spin { app.isServerRunning && !app.ownerAuthorityRefreshInFlight }
    expect(JSONRPCServer.starts == 1, "foreground reconstructs local listener")
    expect(!app.serviceStartLifecyclePending, "foreground creates no lifecycle intent")
    expect(!requests.isEmpty && requests.allSatisfy { $0.httpMethod == "GET" }, "foreground never sends START/ARM/PREWARM")
    app.setApplicationActive(false); app.stopServer()
    print("PASS foreground listener reconstruction does not send Owner START")
}

// The exact supported response is classified once, with no retry or fallback.
do {
    requests = []
    StartupProtocol.handler = { proto in record(proto); proto.reply(503, missingBody) }
    var result: Result<OwnerAuthorityStatus, Error>?
    makeClient().status { result = $0 }
    spin { result != nil }
    guard case .failure(let error) = result! else { fatalError("missing verifier must fail closed") }
    expect(error as? OwnerControlClientError == .verifierUnavailable, "distinct verifier error")
    expect(error as? OwnerControlClientError != .transportFailed, "not transport failure")
    expect(error.localizedDescription.contains("Run PREWARM to restore Owner verifier."), "actual recovery guidance")
    for forbidden in ["uncertain", "timeout", "transport", "unknown delivery"] {
        expect(!error.localizedDescription.lowercased().contains(forbidden), "no misleading delivery language")
    }
    expect(requests.count == 1, "one GET only")
    print("PASS exact 503 verifier response is definitive and distinct from transport uncertainty")

    requests = []
    let app = AppState(client: makeClient(), initial: armed)
    app.appIsActive = true
    app.refreshOwnerAuthorityStatus()
    spin { !app.ownerAuthorityRefreshInFlight }
    expect(app.ownerAuthorityState == .verifierUnavailable && app.ownerAuthorityStatus == nil, "discard stale ARMED, invent no DISARMED")
    expect(app.ownerAuthorityStatusError == error.localizedDescription, "UI gets factual recovery message")
    expect(app.ownerAuthorityRefreshWorkItem == nil, "no automatic retry scheduled")
    observe(for: 2.2)
    expect(requests.count == 1 && requests.allSatisfy { $0.httpMethod == "GET" }, "no automatic retry, ARM or PREWARM")

    // ARM guard remains closed; its existing refresh may only re-read status.
    app.startOwnerControl()
    spin { !app.ownerAuthorityRefreshInFlight }
    expect(requests.allSatisfy { $0.httpMethod == "GET" }, "verifier missing cannot grant ARM")
    expect(app.ownerAuthorityState == .verifierUnavailable, "blocked ARM preserves factual missing-verifier state")

    // Only a later explicitly requested authenticated success changes authority UI.
    StartupProtocol.handler = { proto in record(proto); proto.reply(200, disarmedBody) }
    app.manualRefreshOwnerAuthorityStatus()
    spin { !app.ownerAuthorityRefreshInFlight }
    expect(app.ownerAuthorityState == .disarmed && app.ownerAuthorityStatusError == nil, "manual successful status resumes existing mapping")
    app.setApplicationActive(false)
    print("PASS reconciliation fails closed, shows recovery, pauses polling; explicit refresh can recover")
}

// Matching requires the exact HTTP status, error string, and ok=false envelope.
for (code, body) in [(503, "{}"), (503, "not json"), (500, missingBody),
                     (403, missingBody), (503, "{\"ok\":true,\"error\":\"owner verifier unavailable\"}"),
                     (503, "{\"ok\":false,\"error\":\"other error\"}")] {
    var result: Result<OwnerAuthorityStatus, Error>?
    StartupProtocol.handler = { proto in record(proto); proto.reply(code, body) }
    makeClient().status { result = $0 }; spin { result != nil }
    guard case .failure(let error) = result! else { fatalError("invalid status must fail") }
    expect(error as? OwnerControlClientError == .transportFailed, "unsupported responses preserve existing mapping")
}
do {
    requests = []
    StartupProtocol.handler = { proto in record(proto); proto.timeout() }
    let app = AppState(client: makeClient(), initial: armed)
    app.refreshOwnerAuthorityStatus(); spin { !app.ownerAuthorityRefreshInFlight }
    expect(app.ownerAuthorityState == .unknown && app.ownerAuthorityStatus == nil, "real timeout is UNKNOWN")
    expect(app.ownerAuthorityStatusError?.contains("delivery is uncertain") == true, "real timeout retains uncertainty")
    expect(requests.count == 1, "no client retry on transport failure")
    print("PASS genuine transport failure remains uncertain; unsupported responses retain previous mapping")
}
for (body, state) in [(armedBody, OwnerAuthorityUIState.armed), (disarmedBody, .disarmed)] {
    for compatibility in ["current", "omitted", "2000-01-01T00:00:00Z", "2027-01-01T00:00:00Z"] {
        var wire = try! JSONSerialization.jsonObject(with: Data(body.utf8)) as! [String: Any]
        if compatibility == "omitted" { wire.removeValue(forKey: "absolute_expires_at") }
        else if compatibility != "current" { wire["absolute_expires_at"] = compatibility }
        let response = String(data: try! JSONSerialization.data(withJSONObject: wire), encoding: .utf8)!
        StartupProtocol.handler = { proto in record(proto); proto.reply(200, response) }
        let app = AppState(client: makeClient(), initial: armed)
        app.refreshOwnerAuthorityStatus(); spin { !app.ownerAuthorityRefreshInFlight }
        expect(app.ownerAuthorityState == state && app.ownerAuthorityStatusError == nil, "expiry-inert authenticated authority mapping")
    }
}
print("PASS CURRENT empty/missing and legacy expiry wire snapshots reach ARMED/DISARMED through actual client/reconciliation")
