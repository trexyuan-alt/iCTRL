import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

enum KeychainStore {
    static var data: Data?
    static var reads = 0
    static var writes = 0
    static func load(account: String) -> Data? { precondition(account == "owner-control-v2"); reads += 1; return data }
    static func save(_ data: Data, account: String) { writes += 1 }
    static func clear(account: String) { writes += 1 }
}
enum SecureEnvelope { static func randomBytes(_ count: Int) -> Data? { nil } }
extension Data { var hexString: String { map { String(format: "%02x", $0) }.joined() } }

final class PrewarmMockProtocol: URLProtocol {
    static var calls = 0
    static var body = ""
    static var status = 200
    static var error: Error?
    static var sequence: [String] = []
    static var requests: [String] = []
    static var statusError: Error?
    static var statusSequence: [Int] = []
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.calls += 1
        let trigger = request.httpMethod == "POST"
        precondition(request.url!.absoluteString == "https://gateway.invalid/owner/v1/" + (trigger ? "prewarm" : "prewarm-status"))
        precondition((trigger || request.httpMethod == "GET") && request.httpBody == nil)
        Self.requests.append(request.httpMethod!)
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + String(repeating: "a", count: 64))
        precondition(request.value(forHTTPHeaderField: "X-Owner-Identity") == "ictrl-owner-test")
        precondition(request.value(forHTTPHeaderField: "X-Phone-Control-Generation") == nil)
        if let error = Self.error { client?.urlProtocol(self, didFailWithError: error); return }
        if !trigger, let error = Self.statusError { client?.urlProtocol(self, didFailWithError: error); return }
        let status = Self.statusSequence.isEmpty ? (Self.status == 200 && trigger ? 202 : Self.status) : Self.statusSequence.removeFirst()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        let body = Self.sequence.isEmpty ? Self.body : Self.sequence.removeFirst()
        client?.urlProtocol(self, didLoad: Data(body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}
