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
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func stopLoading() {}
    override func startLoading() {
        Self.calls += 1
        precondition(request.url!.absoluteString == "https://gateway.invalid/owner/v1/prewarm")
        precondition(request.httpMethod == "POST" && request.httpBody == nil)
        precondition(request.value(forHTTPHeaderField: "Authorization") == "Bearer " + String(repeating: "a", count: 64))
        precondition(request.value(forHTTPHeaderField: "X-Owner-Identity") == "ictrl-owner-test")
        precondition(request.value(forHTTPHeaderField: "X-Phone-Control-Generation") == nil)
        if let error = Self.error { client?.urlProtocol(self, didFailWithError: error); return }
        let response = HTTPURLResponse(url: request.url!, statusCode: Self.status, httpVersion: "HTTP/1.1", headerFields: [:])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(Self.body.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
}