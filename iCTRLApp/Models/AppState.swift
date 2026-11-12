import SwiftUI
import Network
import UIKit

/// Foreground control-plane service for the production ZERO-XCTEST Companion.
///
/// The Companion deliberately does NOT expose UI automation. Phone UI reads and
/// mutations stay on the external CoreDevice / RemotePairing / RSD / remoteAX /
/// UniversalHID path. This service only keeps the authenticated bootstrap surface
/// that the backend still needs: /whoami, /pair and the current RemotePairing
/// endpoint oracle.
class AppState: ObservableObject {
    @Published var isServerRunning = false
    @Published var sessions: [AuthSession] = []
    @Published var pendingAuthRequest: PendingAuth?
    @Published var serverAddress: String = "—"
    @Published var serverError: String?

    @AppStorage("autoStartServer") var autoStartServer = false
    @AppStorage("serverPort") var serverPort = 8200
    @AppStorage("allowRemoteAccess") var allowRemoteAccess = true

    /// User-visible bounded background runtime. This is separate from phone
    /// control authority; P0 still decides whether mutations are allowed.
    let backgroundControl = BackgroundControlSession()

    private var server: JSONRPCServer?

    struct PendingAuth: Identifiable {
        let id = UUID()
        let clientName: String
        let completion: (Bool) -> Void
    }

    init() {
        AuthManager.shared.delegate = self
        updateServerAddress()

        backgroundControl.onForcedEnd = { [weak self] in
            // Expiration / system cancellation / 30-minute completion must
            // remove Companion authority immediately. No stale :8200 lease.
            self?.stopServerTransport()
        }

        if autoStartServer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.startServer()
            }
        }
    }

    /// Turn Companion authority ON.
    ///
    /// Production must be remotely reachable because the Render Gateway reaches
    /// :8200 through Tailscale. Authentication is still mandatory for /rpc.
    func startServer() {
        guard !isServerRunning else { return }

        allowRemoteAccess = true
        autoStartServer = true

        let s = JSONRPCServer(port: UInt16(serverPort), localOnly: false)
        server = s

        s.onStateChange = { [weak self] running in
            DispatchQueue.main.async {
                self?.isServerRunning = running
                if running {
                    self?.serverError = nil
                    self?.refreshSessions()
                    self?.updateServerAddress()
                }
            }
        }

        s.onRPCRequest = { method, params, completion in
            switch method {
            case "get_current_remotepairing_endpoint", "remotepairing_endpoint":
                guard params == nil || params?.isEmpty == true else {
                    completion(nil, .invalidParams)
                    return
                }
                // Bonjour resolution intentionally blocks for a bounded snapshot;
                // never run it on the app's main thread or the server listener.
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = RemotePairingEndpointOracle.resolve()
                    completion(result.0, result.1)
                }

            case "device_info":
                guard params == nil || params?.isEmpty == true else {
                    completion(nil, .invalidParams)
                    return
                }
                // Preserve the backend health contract without touching XCTest.
                // A normal app reports the real UIScreen geometry directly; unlike
                // the old compatibility-mode Runner it does not need XCUIApplication.
                DispatchQueue.main.async {
                    let bounds = UIScreen.main.bounds
                    let native = UIScreen.main.nativeBounds
                    completion([
                        "name": .string(UIDevice.current.name),
                        "model": .string(UIDevice.current.model),
                        "system_name": .string(UIDevice.current.systemName),
                        "system_version": .string(UIDevice.current.systemVersion),
                        "point_width": .double(Double(bounds.width)),
                        "point_height": .double(Double(bounds.height)),
                        "pixel_width": .double(Double(native.width)),
                        "pixel_height": .double(Double(native.height)),
                        "scale": .double(Double(UIScreen.main.nativeScale)),
                        "server_version": .string(RPCMethodRegistry.serverVersion),
                        "protocol_version": .int(RPCMethodRegistry.protocolVersion),
                        "mode": .string("zero_xctest_companion"),
                        "capabilities": .array([
                            .string("envelope_v1"),
                            .string("zero_xctest_companion"),
                            .string("get_current_remotepairing_endpoint"),
                            .string("local_oob_stop"),
                            .string("bg_continued_processing_v1"),
                        ]),
                    ], nil)
                }

            default:
                completion(nil, .serverError(
                    "RPC unavailable in ZERO-XCTEST Companion. "
                    + "Phone UI control is provided by CoreDevice/remoteAX/UniversalHID."
                ))
            }
        }

        do {
            try s.start()
            serverError = nil
        } catch {
            print("🔴 Failed to start ZERO-XCTEST Companion: \(error)")
            serverError = error.localizedDescription
            isServerRunning = false
            server = nil
        }
    }

    /// Local independent emergency STOP.
    ///
    /// This does not traverse /rpc or the mounted ChatGPT MCP transport. Closing
    /// :8200 removes the old warm Runner/Companion authority; CURRENT backend P0
    /// Runner-loss handling then invalidates the old control generation.
    func stopServer() {
        backgroundControl.stopOwnerInitiated()
        stopServerTransport()
    }

    /// Explicit Owner action. The system requires continued-processing work to
    /// begin from a foreground user action, so this is never called by
    /// autoStartServer.
    @discardableResult
    func startBackgroundControlSession() -> Bool {
        guard isServerRunning else {
            serverError = "Start the Companion service before background control."
            return false
        }
        return backgroundControl.start()
    }

    private func stopServerTransport() {
        autoStartServer = false
        server?.stop()
        server = nil
        isServerRunning = false
    }

    func refreshSessions() {
        sessions = AuthManager.shared.activeSessions
    }

    func revokeSession(id: String) {
        AuthManager.shared.revokeSession(id: id)
        refreshSessions()
    }

    func revokeAllSessions() {
        AuthManager.shared.revokeAll()
        refreshSessions()
    }

    func updateServerAddress() {
        let ip = getWiFiAddress() ?? "127.0.0.1"
        serverAddress = "\(ip):\(serverPort)"
    }

    private func getWiFiAddress() -> String? {
        var address: String?
        var ifaddr: UnsafeMutablePointer<ifaddrs>?

        guard getifaddrs(&ifaddr) == 0, let firstAddr = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        for ptr in sequence(first: firstAddr, next: { $0.pointee.ifa_next }) {
            let interface = ptr.pointee
            guard let sa = interface.ifa_addr, sa.pointee.sa_family == UInt8(AF_INET) else { continue }

            let name = String(cString: interface.ifa_name)
            guard name == "en0" else { continue }

            var hostname = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            guard getnameinfo(
                sa, socklen_t(sa.pointee.sa_len),
                &hostname, socklen_t(hostname.count),
                nil, 0, NI_NUMERICHOST
            ) == 0 else { continue }
            address = String(cString: hostname)
        }

        return address
    }
}

extension AppState: AuthManagerDelegate {
    func authManager(_ manager: AuthManager, didReceiveAuthRequest clientName: String, requestID: String,
                     nearby: Bool, fingerprint: String?, completion: @escaping (Bool) -> Void) {
        DispatchQueue.main.async {
            self.pendingAuthRequest = PendingAuth(clientName: clientName, completion: completion)
        }
    }

    func authManager(_ manager: AuthManager, didExpireAuthRequest clientName: String, requestID: String) {
        DispatchQueue.main.async {
            if self.pendingAuthRequest?.clientName == clientName { self.pendingAuthRequest = nil }
        }
    }
}
