// Zero-phone acceptance: compile with CURRENT OwnerControlClient/OwnerAuthorityStatus
// and the test host containing unchanged AppState ARM/OFF/status methods.
// artifacts/ws-p1-01/validate_swift.py builds that host from CURRENT source.
import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

final class AuthorityProtocol: URLProtocol {
    static var onRequest: ((AuthorityProtocol) -> Void)?
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() { DispatchQueue.main.async { Self.onRequest?(self) } }
    override func stopLoading() {}
    func reply(_ body: String, status: Int = 200) {
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    func loseResponse() { client?.urlProtocol(self, didFailWithError: URLError(.timedOut)) }
}

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    if !condition() { fatalError("FAIL: \(message)") }
}
func spin(_ predicate: () -> Bool) {
    let end = Date().addingTimeInterval(4)
    while !predicate() && Date() < end { _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.005)) }
    expect(predicate(), "bounded asynchronous acceptance did not settle")
}
func snapshot(armed: Bool, epoch: UInt64 = 8, extras: String = "") -> String {
    let binding = armed ? 3 : 0
    let absolute = "" // CURRENT authority has no absolute authorization TTL.
    let state = armed ? "RUNNING" : "STOPPED"
    return "{\"ok\":true,\"owner_armed\":\(armed),\"authority_epoch\":\(epoch),\"armed_generation\":\(binding),\"absolute_expires_at\":\"\(absolute)\",\"control_state\":\"\(state)\",\"control_generation\":\(armed ? 3 : 4)\(extras)}"
}
func makeClient() -> OwnerControlClient {
    let config = URLSessionConfiguration.ephemeral
    config.protocolClasses = [AuthorityProtocol.self]
    return OwnerControlClient(credential: OwnerControlCredential(baseURL: "https://zero-phone.invalid", identity: "owner-test", token: String(repeating: "a", count: 64), createdAt: Date()), session: URLSession(configuration: config))
}
func decode(_ raw: String) -> OwnerAuthorityStatus { try! JSONDecoder().decode(OwnerAuthorityStatus.self, from: Data(raw.utf8)) }

// Run actual AppState entrypoints with the actual URLSession client. Hold the
// GET response to observe UNKNOWN after loss, before authoritative reconciliation.
for action in ["arm", "off"] {
    var posts = 0
    var gets = 0
    var pendingGET: AuthorityProtocol?
    AuthorityProtocol.onRequest = { proto in
        expect(proto.request.value(forHTTPHeaderField: "Authorization") == "Bearer " + String(repeating: "a", count: 64), "Owner credential must be forwarded")
        if proto.request.httpMethod == "POST" {
            posts += 1
            let payload = try! JSONSerialization.jsonObject(with: proto.request.httpBody!) as! [String: Any]
            expect(payload["action"] as? String == action, "one intended Owner action")
            if action == "arm" { expect((payload["expected_authority_epoch"] as? NSNumber)?.uint64Value == 7, "ARM carries last GET epoch") }
            proto.loseResponse() // server committed; response delivery disappeared
        } else {
            gets += 1
            expect(proto.request.value(forHTTPHeaderField: "X-Owner-Identity") == "owner-test", "reconciliation GET must authenticate identity")
            pendingGET = proto
        }
    }
    let app = AppState(client: makeClient(), initial: decode(snapshot(armed: action == "off", epoch: 7)))
    if action == "arm" { app.startOwnerControl() } else { app.stopOwnerControl() }
    expect(app.ownerAuthorityState == .unknown, "transition starts UNKNOWN")
    spin { pendingGET != nil }
    expect(app.ownerAuthorityState == .unknown && app.ownerAuthorityStatus == nil, "lost POST is UNKNOWN until GET")
    expect(app.serverError?.contains("delivery uncertain") == true, "delivery loss is not factual ARM/OFF failure")
    pendingGET!.reply(snapshot(armed: action == "arm"))
    spin { app.ownerAuthorityState == (action == "arm" ? .armed : .disarmed) }
    expect(app.ownerAuthorityStatus?.authorityEpoch == 8 && posts == 1 && gets == 1, "GET revision settles UI with no second POST")
    print("PASS \(action.uppercased()) delivery loss -> UNKNOWN -> authenticated GET -> authoritative UI; one POST")
}

// Acknowledgement payload cannot grant UI authority; only GET can settle it.
do {
    var pendingGET: AuthorityProtocol?
    var posts = 0
    AuthorityProtocol.onRequest = { proto in
        if proto.request.httpMethod == "POST" { posts += 1; proto.reply(snapshot(armed: true)) } else { pendingGET = proto }
    }
    let app = AppState(client: makeClient(), initial: decode(snapshot(armed: false, epoch: 7)))
    app.startOwnerControl()
    spin { pendingGET != nil }
    expect(app.ownerAuthorityState == .unknown, "POST success is not UI authority")
    pendingGET!.loseResponse()
    spin { !app.ownerAuthorityRefreshInFlight }
    expect(app.ownerAuthorityState == .unknown && app.ownerAuthorityStatus == nil && posts == 1, "status failure is UNKNOWN, never inferred OFF; no resend")
    print("PASS POST acknowledgement not UI authority; GET transport failure remains UNKNOWN")
}

// A delayed pre-action read must not overwrite the action's reconciliation.
do {
    var pending: [AuthorityProtocol] = []
    AuthorityProtocol.onRequest = { proto in
        if proto.request.httpMethod == "POST" { proto.loseResponse() } else { pending.append(proto) }
    }
    let app = AppState(client: makeClient(), initial: decode(snapshot(armed: false, epoch: 7)))
    app.refreshOwnerAuthorityStatus()
    spin { pending.count == 1 }
    app.startOwnerControl()
    spin { pending.count == 2 }
    pending[1].reply(snapshot(armed: true, epoch: 8))
    spin { app.ownerAuthorityState == .armed }
    pending[0].reply(snapshot(armed: false, epoch: 7))
    _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.05))
    expect(app.ownerAuthorityState == .armed && app.ownerAuthorityStatus?.authorityEpoch == 8, "old read cannot overwrite newer transition reconciliation")
    print("PASS stale pre-transition GET cannot overwrite current revision")
}

// Status is usable with no readiness/service schema and even contrary optional
// service facts. Strict required revision/binding decode rejects malformed data.
for extras in ["", ",\"execution_ready\":false,\"service_state\":\"OFF\""] {
    let raw = snapshot(armed: true, extras: extras)
    var result: Result<OwnerAuthorityStatus, Error>?
    AuthorityProtocol.onRequest = { $0.reply(raw) }
    makeClient().status { result = $0 }
    spin { result != nil }
    if case .success(let status) = result! { expect(status.uiState == .armed, "RSD/service cannot rewrite Owner permission") } else { fatalError("schema mismatch") }
}
for field in ["authority_epoch", "armed_generation"] {
    var obj = try! JSONSerialization.jsonObject(with: Data(snapshot(armed: true).utf8)) as! [String: Any]
    obj.removeValue(forKey: field)
    let data = try! JSONSerialization.data(withJSONObject: obj)
    expect((try? JSONDecoder().decode(OwnerAuthorityStatus.self, from: data)) == nil, "missing revision/binding must fail closed")
}
for epoch: Any in [true, -1, "8", 1.5] {
    var obj = try! JSONSerialization.jsonObject(with: Data(snapshot(armed: true).utf8)) as! [String: Any]
    obj["authority_epoch"] = epoch
    expect((try? JSONDecoder().decode(OwnerAuthorityStatus.self, from: JSONSerialization.data(withJSONObject: obj))) == nil, "malformed epoch must fail closed")
}
print("PASS optional readiness/service and strict authoritative revision schema")

// Explicit stale revision conflict is a rejection, followed by GET, never resend.
do {
    var posts = 0
    AuthorityProtocol.onRequest = { proto in
        if proto.request.httpMethod == "POST" { posts += 1; proto.reply("{\"ok\":false,\"authority_epoch\":9}", status: 409) }
        else { proto.reply(snapshot(armed: false, epoch: 9)) }
    }
    let app = AppState(client: makeClient(), initial: decode(snapshot(armed: false, epoch: 7)))
    app.startOwnerControl()
    spin { app.ownerAuthorityStatus?.authorityEpoch == 9 }
    expect(app.ownerAuthorityState == .disarmed && posts == 1 && app.serverError?.contains("rejected") == true, "stale expected epoch cannot auto-resend ARM")
    print("PASS stale ARM conflict reconciles current OFF without resend")
}
print("PASS WS-P1-01 response loss zero-phone acceptance; PHONE_OPERATION_COUNT=0")
