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
    @Published private(set) var ownerAuthorityState: OwnerAuthorityUIState = .unknown
    @Published private(set) var ownerAuthorityStatus: OwnerAuthorityStatus?
    @Published private(set) var ownerAuthorityStatusError: String?
    @Published var ownerControlBusy = false
    @Published var ownerControlProvisioned = OwnerControlCredentialStore.load() != nil

    var ownerControlActive: Bool { ownerAuthorityState == .armed }

    @AppStorage("autoStartServer") var autoStartServer = false
    @AppStorage("serverPort") var serverPort = 8200
    @AppStorage("allowRemoteAccess") var allowRemoteAccess = true

    private var server: JSONRPCServer?
    private var ownerControlClient: OwnerControlClient? { OwnerControlClient.fromKeychain() }
    private var appIsActive = false
    private var serverStartInFlight = false
    private var restartWorkItem: DispatchWorkItem?
    @Published private(set) var ownerAuthorityRefreshInFlight = false
    private var ownerAuthorityRefreshWorkItem: DispatchWorkItem?
    private var serviceStartLifecyclePending = false

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
                self?.startCompanionService()
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
                    self.refreshOwnerAuthorityStatus()
                    self.fulfillPendingServiceStartIfNeeded()
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
                        self.ownerAuthorityState = .unknown
                        self.ownerAuthorityStatus = nil
                        self.ownerAuthorityStatusError = nil
                        self.serverError = nil
                        self.refreshOwnerAuthorityStatus()
                        self.fulfillPendingServiceStartIfNeeded()
                    }
                    completion([
                        "identity": .string(credential.identity),
                        "token": .string(credential.token),
                        "storage": .string("keychain"),
                        "scope": .string("owner_authority_service_lifecycle"),
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
                    self.ownerAuthorityState = .unknown
                    self.ownerAuthorityStatus = nil
                    self.ownerAuthorityStatusError = "Owner authority status unavailable."
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
            // Never carry a cached ARMED presentation across a foreground
            // transition. Reconcile the listener and immediately fetch the
            // authoritative Owner snapshot before presenting control authority.
            ownerAuthorityState = .unknown
            ownerAuthorityStatus = nil
            ownerAuthorityStatusError = nil
            reconcileCompanionService()
            refreshOwnerAuthorityStatus()
            scheduleOwnerAuthorityRefreshIfNeeded()
        } else {
            restartWorkItem?.cancel()
            restartWorkItem = nil
            ownerAuthorityRefreshWorkItem?.cancel()
            ownerAuthorityRefreshWorkItem = nil
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

    /// Refresh Owner UI state from the authenticated server snapshot only.
    /// This method never sends ARM/OFF and never changes control generation.
    func refreshOwnerAuthorityStatus() {
        guard !ownerAuthorityRefreshInFlight, !ownerControlBusy else { return }
        guard ownerControlProvisioned, let client = ownerControlClient else {
            ownerAuthorityState = .unknown
            ownerAuthorityStatus = nil
            ownerAuthorityStatusError = "Owner authority status unavailable."
            return
        }

        ownerAuthorityRefreshInFlight = true
        client.status { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.ownerAuthorityRefreshInFlight = false
                switch result {
                case .success(let status):
                    self.ownerAuthorityStatus = status
                    self.ownerAuthorityState = status.uiState
                    self.ownerAuthorityStatusError = nil
                case .failure(let error):
                    // A failed read must never preserve a stale ARMED display.
                    self.ownerAuthorityStatus = nil
                    self.ownerAuthorityState = .unknown
                    self.ownerAuthorityStatusError = "Owner authority status unavailable: \(error.localizedDescription)"
                }
            }
        }
    }

    /// While foregrounded, periodically reconcile backend fail-closed revokes
    /// that have no push channel back into the app.
    private func scheduleOwnerAuthorityRefreshIfNeeded() {
        ownerAuthorityRefreshWorkItem?.cancel()
        guard appIsActive else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.refreshOwnerAuthorityStatus()
            self.scheduleOwnerAuthorityRefreshIfNeeded()
        }
        ownerAuthorityRefreshWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
    }

    /// User-facing service START. Local Companion must be running before the
    /// explicit service lifecycle event is sent. This never ARM's Owner authority.
    func startCompanionService() {
        guard !ownerControlBusy else { return }
        serviceStartLifecyclePending = true
        serverError = nil
        startServer()
        fulfillPendingServiceStartIfNeeded()
    }

    private func fulfillPendingServiceStartIfNeeded() {
        guard serviceStartLifecyclePending, isServerRunning, !ownerControlBusy else { return }
        guard ownerControlProvisioned, let client = ownerControlClient else { return }

        // Consume the one explicit START intent before I/O. A failed OOB request is
        // returned to the Owner; it is never retried implicitly.
        serviceStartLifecyclePending = false
        ownerControlBusy = true
        client.service(.start) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.ownerControlBusy = false
                self.ownerAuthorityState = .unknown
                self.ownerAuthorityStatus = nil
                switch result {
                case .success:
                    self.serverError = nil
                case .failure(let error):
                    self.serverError = "Owner service START failed: \(error.localizedDescription)"
                }
                self.refreshOwnerAuthorityStatus()
            }
        }
    }

    /// User-facing service STOP. Full server-side revoke must be acknowledged
    /// before the local Companion listener is torn down. Failure never degrades
    /// into a transport-only disconnect masquerading as STOP.
    func stopCompanionService() {
        guard !ownerControlBusy else { return }
        serviceStartLifecyclePending = false
        guard let client = ownerControlClient else {
            serverError = "Owner service STOP failed: OOB configuration unavailable. Service remains locally running."
            refreshOwnerAuthorityStatus()
            return
        }

        ownerControlBusy = true
        serverError = nil
        client.service(.stop) { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.ownerControlBusy = false
                self.ownerAuthorityState = .unknown
                self.ownerAuthorityStatus = nil
                switch result {
                case .success:
                    self.stopServer()
                    self.serverError = nil
                case .failure(let error):
                    self.serverError = "Owner service STOP failed: \(error.localizedDescription). Service remains locally running."
                }
                self.refreshOwnerAuthorityStatus()
            }
        }
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
        guard ownerAuthorityState == .disarmed else {
            serverError = "Owner ARM blocked: authoritative status is not DISARMED."
            refreshOwnerAuthorityStatus()
            return
        }
        serverError = nil

        // First install / rotated credential bootstrap: keep the normal Companion
        // foreground listener available for the already-paired encrypted
        // provisioning RPC. Do not create Owner authority until a Keychain
        // credential exists and the Owner presses ON again.
        guard ownerControlProvisioned, let client = ownerControlClient else {
            ownerAuthorityState = .unknown
            ownerAuthorityStatus = nil
            serverError = "Owner control credential is not provisioned yet. Keep iCTRL open for secure provisioning."
            return
        }

        ownerControlBusy = true
        client.arm { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.ownerControlBusy = false
                self.ownerAuthorityState = .unknown
                self.ownerAuthorityStatus = nil
                switch result {
                case .success:
                    self.serverError = nil
                case .failure(let error):
                    // ARM failure must not destroy unrelated foreground
                    // Companion service state. :8200 remains available for
                    // provisioning/bootstrap/endpoint refresh.
                    self.serverError = "Owner ARM failed: \(error.localizedDescription)"
                }
                // The POST acknowledgement is not UI authority. Always fetch
                // the authoritative snapshot after ARM completion.
                self.refreshOwnerAuthorityStatus()
            }
        }
    }

    /// Explicit independent Owner OFF / emergency STOP ingress.
    ///
    /// OFF is acknowledged by the authoritative backend and does not change
    /// the independent :8200 Companion service lifecycle.
    func stopOwnerControl() {
        guard !ownerControlBusy else { return }
        guard ownerAuthorityState == .armed else {
            serverError = "Owner OFF blocked: authoritative status is not ARMED."
            refreshOwnerAuthorityStatus()
            return
        }
        guard let client = ownerControlClient else {
            ownerAuthorityState = .unknown
            ownerAuthorityStatus = nil
            serverError = "Owner OFF failed: OOB configuration unavailable. Remote authority may still be active."
            return
        }
        ownerControlBusy = true
        serverError = nil
        client.off { [weak self] result in
            DispatchQueue.main.async {
                guard let self else { return }
                self.ownerControlBusy = false
                self.ownerAuthorityState = .unknown
                self.ownerAuthorityStatus = nil
                switch result {
                case .success:
                    self.serverError = nil
                case .failure(let error):
                    self.serverError = "Owner OFF failed: \(error.localizedDescription). Remote authority may still be active."
                }
                // The POST acknowledgement is not UI authority. Always fetch
                // the authoritative snapshot after OFF completion.
                self.refreshOwnerAuthorityStatus()
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
