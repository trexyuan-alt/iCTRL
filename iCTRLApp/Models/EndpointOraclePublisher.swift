import CryptoKit
import Foundation

/// Production RemotePairing endpoint publisher for the normal iCTRL app.
///
/// It performs only local DNS-SD discovery plus outbound HTTPS. It never opens
/// RemotePairing, Pair Verify, CoreDevice, screenshot, HID, or any automation
/// service. The backend secret is installation-local and is used only to bind
/// this app install to its Render cache record.
final class EndpointOraclePublisher {
    static let shared = EndpointOraclePublisher()

    private let queue = DispatchQueue(label: "com.openminis.ictrl.endpoint-publisher")
    private let defaults = UserDefaults.standard
    private let baseURL = URL(string: "https://iphone-coredevice-observation.onrender.com")!
    private let iso = ISO8601DateFormatter()
    private var apnsToken: String?
    private var lastRefresh = Date.distantPast
    private var started = false

    private var backendIdentity: String {
        if let value = defaults.string(forKey: "rpEndpointBackendIdentity"), !value.isEmpty {
            return value
        }
        let value = UUID().uuidString.lowercased()
        defaults.set(value, forKey: "rpEndpointBackendIdentity")
        return value
    }

    private var backendSecret: String {
        if let value = defaults.string(forKey: "rpEndpointBackendSecret"), !value.isEmpty {
            return value
        }
        let key = SymmetricKey(size: .bits256)
        let value = key.withUnsafeBytes { Data($0).base64EncodedString() }
        defaults.set(value, forKey: "rpEndpointBackendSecret")
        return value
    }

    func start() {
        queue.async {
            guard !self.started else { return }
            self.started = true
            self.registerBackend(apnsToken: self.apnsToken) { _ in
                self.refreshAndPublish(reason: "launch", completion: nil)
            }
        }
    }

    func refreshIfNeeded(reason: String) {
        queue.async {
            guard Date().timeIntervalSince(self.lastRefresh) >= 60 else { return }
            self.refreshAndPublish(reason: reason, completion: nil)
        }
    }

    func updateAPNSToken(_ token: Data) {
        let value = token.map { String(format: "%02x", $0) }.joined()
        queue.async {
            self.apnsToken = value
            self.registerBackend(apnsToken: value, completion: nil)
        }
    }

    func registerBackend(apnsToken: String?, completion: ((Bool) -> Void)?) {
        queue.async {
            var body: [String: Any] = [
                "backend_identity": self.backendIdentity,
                "apns_environment": "development",
                "bundle_id": Bundle.main.bundleIdentifier ?? "com.openminis.ictrl",
            ]
            if let apnsToken, !apnsToken.isEmpty {
                body["apns_token"] = apnsToken
            }
            self.post(path: "/coredevice/v1/endpoint/register", body: body, completion: completion)
        }
    }

    func refreshAndPublish(reason: String, completion: ((Bool) -> Void)?) {
        queue.async {
            // Registration is idempotent and ensures a Render restart can be
            // repopulated before the next cache publication.
            self.registerBackend(apnsToken: self.apnsToken) { registered in
                guard registered else {
                    completion?(false)
                    return
                }

                let observedAt = self.iso.string(from: Date())
                let (result, _) = RemotePairingEndpointOracle.resolve()
                var body: [String: Any] = [
                    "backend_identity": self.backendIdentity,
                    "observed_at": observedAt,
                    "reason": reason,
                ]

                if let result,
                   let port = result["port"]?.intValue,
                   (1...65535).contains(port),
                   let identifier = result["identifier"]?.stringValue,
                   !identifier.isEmpty,
                   let authTag = result["authTag"]?.stringValue,
                   !authTag.isEmpty {
                    body["status"] = "resolved"
                    body["port"] = port
                    body["identifier"] = identifier
                    body["authTag"] = authTag
                    if let wire = result["wireProtocolVersion"]?.stringValue, !wire.isEmpty {
                        body["wireProtocolVersion"] = wire
                    }
                } else {
                    // A failed refresh never overwrites the last known-good
                    // endpoint on Render; it only records that one bounded
                    // refresh attempt completed without a usable answer.
                    body["status"] = "unavailable"
                }

                self.post(path: "/coredevice/v1/endpoint/publish", body: body) { ok in
                    if ok { self.lastRefresh = Date() }
                    completion?(ok)
                }
            }
        }
    }

    private func post(path: String, body: [String: Any], completion: ((Bool) -> Void)?) {
        guard JSONSerialization.isValidJSONObject(body),
              let data = try? JSONSerialization.data(withJSONObject: body),
              let url = URL(string: path, relativeTo: baseURL) else {
            completion?(false)
            return
        }
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.timeoutInterval = 10
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(backendSecret)", forHTTPHeaderField: "Authorization")
        request.httpBody = data

        URLSession.shared.dataTask(with: request) { _, response, error in
            let code = (response as? HTTPURLResponse)?.statusCode ?? 0
            let ok = error == nil && (200...299).contains(code)
            if !ok {
                ictrlLog("Endpoint publisher \(path) failed (HTTP \(code))")
            }
            completion?(ok)
        }.resume()
    }

    static func isEndpointRefreshPush(_ userInfo: [AnyHashable: Any]) -> Bool {
        if let n = userInfo["rp_endpoint_refresh"] as? NSNumber { return n.boolValue }
        if let s = userInfo["rp_endpoint_refresh"] as? String { return s == "1" || s.lowercased() == "true" }
        return false
    }
}
