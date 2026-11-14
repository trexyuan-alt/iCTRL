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
    @Published var ownerControlActive = false
    @Published var ownerControlBusy = false
    @Published var ownerControlProvisioned = OwnerControlCredentialStore.load() != nil

    @AppStorage("autoStartServer") var autoStartServer = false
    @AppStorage("serverPort") var serverPort = 8200
    @AppStorage("allowRemoteAccess") var allowRemoteAccess = true

    private var server: JSONRPCServer?
    private var ownerControlClient: OwnerControlClient? { OwnerControlClient.fromKeychain() }
    private var appIsActive = false
    private var serverStartInFlight = false
    private var restartWorkItem: DispatchWorkItem?

    struct PendingAuth: Identifiable {
        let id = UUID()
        let clientName: String
        let completion: (Bool) -> Void
    }

    init() {
        AuthManager.shared.delegate = self
        updateServerAddress()

        if autoStartServer {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                self?.startServer()
            }
        }
    }

    /// Start or restart the foreground Companion service only.
    ///
    /// This never creates Owner authority. The listener is remotely reachable
    /// because the Render Gateway reaches :8200 through Tailscale; /rpc remains
    /// authenticated.
    func startServer() {
        allowRemoteAccess = true
        autoStartServer = true
        restartWorkItem?.cancel()
        restartWorkItem = nil

        guard !isServerRunning, !serverStartInFlight else { return }

        // A failed/cancelled NWListener can leave a stale server object behind.
        // Dispose it before constructing a fresh listener so a foreground return
        // can recover without force-closing iCTRL.
        if let stale = server {
            server = nil
            stale.stop()
        }

        serverStartInFlight = true
        let s = JSONRPCServer(port: UInt16(serverPort), localOnly: false)
        server = s

        s.onStateChange = { [weak self, weak s] running in
            DispatchQueue.main.async {
                guard let self, let s, self.server === s else { return }
                self.serverStartInFlight = false
                self.isServerRunning = running
                if running {
                    self.serverError = nil
                    self.refreshSessions()
                    self.updateServerAddress()
                } else {
                    self.scheduleServerRestartIfNeeded()
                }
            }
        }

        s.onRPCRequest = { method, params, completion in
            switch method {
            case "owner_control_provision":
                guard let params,
                      params.count == 1,
                      let baseURL = params["base_url"]?.stringValue else {
                    completion(nil, .invalidParams)
                    return
                }
                do {
                    let credential = try OwnerControlCredentialStore.ensure(baseURL: baseURL)
                    DispatchQueue.main.async {
                        self.ownerControlProvisioned = true
                        self.serverError = nil
                    }
                    completion([
                        "identity": .string(credential.identity),
                        "token": .string(credential.token),
                        "storage": .string("keychain"),
                        "scope": .string("owner_arm_off_only"),
                    ], nil)
                } catch {
                    completion(nil, .serverError("Owner control provisioning failed"))
                }

            case "owner_control_clear":
                guard params == nil || params?.isEmpty == true else {
                    completion(nil, .invalidParams)
                    return
                }
                OwnerControlCredentialStore.clear()
                DispatchQueue.main.async {
                    self.ownerControlProvisioned = false
                    self.ownerControlActive = false
                }
                completion(["cleared": .bool(true)], nil)

            case "get_current_remotepairing_endpoint", "remotepairing_endpoint":
                guard params == nil || params?.isEmpty == true else {
                    completion(nil, .invalidParams)
                    return
                }
                DispatchQueue.global(qos: .userInitiated).async {
                    let result = RemotePairingEndpointOracle.resolve()
                    completion(result.0, result.1)
                }

            case "recovery_pairing_gate":
                guard params == nil || params?.isEmpty == true else {
                    completion(nil, .invalidParams)
                    return
                }
                DispatchQueue.main.async {
                    guard self.appIsActive, self.isServerRunning else {
                        completion(nil, .serverError("Recovery pairing requires foreground Companion"))
                        return
                    }
                    let deviceID = NearbyIdentity.deviceID
                    DispatchQueue.global(qos: .userInitiated).async {
                        let result = RemotePairingEndpointOracle.resolve()
                        guard let endpoint = result.0, result.1 == nil else {
                            completion(nil, result.1 ?? .serverError("RemotePairing identity is ambiguous"))
                            return
                        }
                        completion([
                            "foreground_active": .bool(true),
                            "device_id": .string(deviceID),
                            "endpoint": .object(endpoint),
                            "recovery_only": .bool(true),
                            "ui_mutation": .bool(false),
                        ], nil)
                    }
                }

            case "device_info":
                guard params == nil || params?.isEmpty == true else {
                    completion(nil, .invalidParams)
                    return
                }
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
            if server === s { server = nil }
            serverStartInFlight = false
            serverError = error.localizedDescription
            isServerRunning = false
            scheduleServerRestartIfNeeded()
        }
    }

    /// Track foreground state and reconcile the Companion listener on resume.
    func setApplicationActive(_ active: Bool) {
        appIsActive = active
        if active {
            reconcileCompanionService()
        } else {
            restartWorkItem?.cancel()
            restartWorkItem = nil
        }
    }

    /// Rebuild a dead foreground listener without touching Owner authority.
    func reconcileCompanionService() {
        guard appIsActive, autoStartServer, !isServerRunning, !serverStartInFlight else { return }
        startServer()
    }

    private func scheduleServerRestartIfNeeded() {
        restartWorkItem?.cancel()
        guard appIsActive, autoStartServer else { return }
        let work = DispatchWorkItem { [weak self] in
            self?.reconcileCompanionService()
        }
        restartWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.75, execute: work)
    }

    /// Explicit Owner ARM ingress.
    ///
    /// Owner authorization is carried only by the Keychain-backed Owner
    /// credential. The backend selects a CURRENT cryptographically validated
    /// RemotePairing snapshot and proves live RSD before creating authority.
    /// Bonjour remains available separately through the foreground Companion
    /// endpoint oracle for bootstrap/refresh, but it is not an ARM dependency.
    func startOwnerControl() {
        guard !ownerControlBusy else { return }
        serverError = nil

        // First install / rotated credential bootstrap: keep the normal Companion
        // foreground listener available for the already-paired encrypted
        // provisioning RPC. Do not create Owner authority until a Keychain
        // credential exists and the Owner presses ON again.
        guard ownerControlProvisioned, let client = ownerControlClient else {
            ownerControlActive = false
            serverError = "Owner control credential is not provisioned yet. Keep iCTRL open for secure provisioning."
            return
        }

        ownerControlBusy = true
        client.arm { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.ownerControlBusy = false
                switch result {
                case .success:
                    self.ownerControlActive = true
                    self.serverError = nil
                case .failure(let error):
                    self.ownerControlActive = false
                    // ARM failure must not destroy unrelated foreground
                    // Companion service state. :8200 remains available for
                    // provisioning/bootstrap/endpoint refresh.
                    self.serverError = "Owner ARM failed: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Explicit independent Owner OFF / emergency STOP ingress.
    ///
    /// OFF is acknowledged by the authoritative backend and does not change
    /// the independent :8200 Companion service lifecycle.
    func stopOwnerControl() {
        guard !ownerControlBusy else { return }
        guard let client = ownerControlClient else {
            serverError = "Owner OFF failed: OOB configuration unavailable. Remote authority may still be active."
            return
        }
        ownerControlBusy = true
        serverError = nil
        client.off { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.ownerControlBusy = false
                switch result {
                case .success:
                    self.ownerControlActive = false
                case .failure(let error):
                    self.serverError = "Owner OFF failed: \(error.localizedDescription). Remote authority may still be active."
                }
            }
        }
    }

    /// Local listener teardown only. This is NOT an authority revoke in V2.
    func stopServer() {
        autoStartServer = false
        restartWorkItem?.cancel()
        restartWorkItem = nil
        serverStartInFlight = false
        let current = server
        server = nil
        current?.stop()
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
