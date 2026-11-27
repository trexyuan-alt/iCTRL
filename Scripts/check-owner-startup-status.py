"""Zero-phone Swift tests using verbatim current AppState method bodies.

Only platform services are replaced: the listener is an in-memory fake,
URLSession uses URLProtocol, and Keychain/UIKit/SwiftUI are test doubles.
No production app is built and no request reaches a network or phone.
"""
from pathlib import Path
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
SOURCE = (ROOT / 'iCTRLApp/Models/AppState.swift').read_text(encoding='utf-8-sig')


def method(name):
    marker = '    init(' if name == 'init' else 'func ' + name + '('
    start = SOURCE.index(marker)
    start = SOURCE.rfind('\n', 0, start) + 1
    brace = SOURCE.index('{', start)
    depth, end = 1, brace + 1
    while depth:
        depth += (SOURCE[end] == '{') - (SOURCE[end] == '}')
        end += 1
    return SOURCE[start:end]


METHODS = ['init', 'startServer', 'setApplicationActive', 'reconcileCompanionService',
           'scheduleServerRestartIfNeeded', 'beginOwnerAuthorityTransientPolling',
           'manualRefreshOwnerAuthorityStatus', 'refreshOwnerAuthorityStatus',
           'scheduleOwnerAuthorityRefreshIfNeeded', 'startCompanionService',
           'fulfillPendingServiceStartIfNeeded', 'stopCompanionService',
           'startOwnerControl', 'stopOwnerControl', 'stopServer', 'refreshSessions']

HOST = '''import Foundation
final class AppState {
    var isServerRunning = false
    var sessions: [AuthSession] = []
    var serverError: String?
    var ownerAuthorityState: OwnerAuthorityUIState = .unknown
    var ownerAuthorityStatus: OwnerAuthorityStatus?
    var ownerAuthorityStatusError: String?
    var ownerControlBusy = false
    var ownerControlProvisioned = true
    var autoStartServer = TestEnvironment.autoStart
    var serverPort = 8200
    var allowRemoteAccess = true
    private var server: JSONRPCServer?
    private var ownerControlClient: OwnerControlClient? { TestEnvironment.client }
    var appIsActive = false
    var serverStartInFlight = false
    var restartWorkItem: DispatchWorkItem?
    var ownerAuthorityRefreshInFlight = false
    var ownerAuthorityRefreshWorkItem: DispatchWorkItem?
    var ownerAuthorityReadSequence: UInt64 = 0
    var ownerAuthorityTransientUntil: Date?
    var serviceStartLifecyclePending = false
    func updateServerAddress() {}
    init(client: OwnerControlClient, initial: OwnerAuthorityStatus) {
        TestEnvironment.client = client
        ownerAuthorityStatus = initial
        ownerAuthorityState = initial.uiState
    }
''' + '\n'.join(method(n) for n in METHODS) + '\n}\n'

STUBS = '''import Foundation
enum TestEnvironment {
    static var autoStart = false
    static var client: OwnerControlClient?
}
struct AuthSession {}
final class AuthManager {
    static let shared = AuthManager()
    var delegate: AnyObject?
    var activeSessions: [AuthSession] = []
}
enum KeychainStore {
    static func load(account: String) -> Data? { nil }
    static func save(_ data: Data, account: String) {}
    static func clear(account: String) {}
}
enum SecureEnvelope { static func randomBytes(_ count: Int) -> Data? { nil } }
extension Data { var hexString: String { map { String(format: "%02x", $0) }.joined() } }
indirect enum RPCValue {
    case string(String), bool(Bool), double(Double), int(Int)
    case object([String: RPCValue]), array([RPCValue])
    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
}
enum RPCError: Error { case invalidParams, serverError(String) }
final class JSONRPCServer {
    static var starts = 0
    static var last: JSONRPCServer?
    var ownerProvisionDiagnosticID: String? { nil }
    func ownerProvisionDiagnostic(_ id: String?, stage: String, result: String? = nil) {}
    var onStateChange: ((Bool) -> Void)?
    var onRPCRequest: ((String, [String: RPCValue]?, @escaping ([String: RPCValue]?, RPCError?) -> Void) -> Void)?
    init(port: UInt16, localOnly: Bool) { precondition(port == 8200 && !localOnly) }
    func start() throws { Self.starts += 1; Self.last = self; onStateChange?(true) }
    func stop() {}
}
enum RemotePairingEndpointOracle {
    static func resolve() -> ([String: RPCValue]?, RPCError?) { fatalError("RSD must not run") }
}
enum NearbyIdentity { static let deviceID = "test-only" }
struct TestBounds { let width = 1.0; let height = 1.0 }
final class UIScreen {
    static let main = UIScreen()
    let bounds = TestBounds(); let nativeBounds = TestBounds(); let nativeScale = 1.0
}
final class UIDevice {
    static let current = UIDevice()
    let name = "fake"; let model = "fake"; let systemName = "fake"; let systemVersion = "fake"
}
enum RPCMethodRegistry { static let serverVersion = "test"; static let protocolVersion = 1 }
'''


def run(*args):
    print('+', *map(str, args), flush=True)
    subprocess.run(list(map(str, args)), check=True, cwd=ROOT)


with tempfile.TemporaryDirectory(prefix='ictrl-owner-tests-') as directory:
    out = Path(directory)
    (out / 'host.swift').write_text(HOST)
    (out / 'stubs.swift').write_text(STUBS)
    common = [ROOT / 'iCTRLApp/Models/OwnerAuthorityStatus.swift',
              ROOT / 'iCTRLApp/Models/OwnerAuthorityPollingPolicy.swift',
              ROOT / 'iCTRLApp/Models/OwnerControlClient.swift',
              out / 'host.swift', out / 'stubs.swift']
    for name in ['owner_startup_verifier_zero_phone', 'owner_authority_state_zero_phone',
                 'owner_status_polling_zero_phone', 'owner_authority_response_loss_zero_phone']:
        (out / 'main.swift').write_bytes((ROOT / 'Scripts' / (name + '.swift')).read_bytes())
        run('swiftc', '-swift-version', '5', *common, out / 'main.swift', '-o', out / 'test')
        run(out / 'test')
    run('swiftc', '-frontend', '-parse', ROOT / 'iCTRLApp/Models/AppState.swift',
        ROOT / 'iCTRLApp/Views/SettingsView.swift')
    run('sh', ROOT / 'Scripts/check-prewarm.sh')
