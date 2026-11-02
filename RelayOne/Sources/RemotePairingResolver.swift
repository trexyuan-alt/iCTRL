import Foundation
import dnssd

struct RemotePairingEndpoint: Codable, Equatable {
    let port: Int
    let identifier: String
    let authTag: String
    let wireProtocolVersion: String?
}

private struct RPService {
    let name: String
    let type: String
    let domain: String
}

private final class RPBrowseState {
    let lock = NSLock()
    var services: [String: RPService] = [:]
}

private final class RPResolveState {
    let lock = NSLock()
    var endpoint: RemotePairingEndpoint?
    var error: Error?
    let done = DispatchSemaphore(value: 0)
    private var finished = false

    func finish(endpoint: RemotePairingEndpoint? = nil, error: Error? = nil) {
        lock.lock()
        guard !finished else { lock.unlock(); return }
        finished = true
        self.endpoint = endpoint
        self.error = error
        lock.unlock()
        done.signal()
    }
}

private enum RPResolverError: LocalizedError {
    case browseStart(Int32)
    case browseAttach
    case noService
    case resolveStart(Int32)
    case resolveAttach
    case resolveTimeout
    case resolveFailed(Int32)
    case metadataMissing

    var errorDescription: String? {
        switch self {
        case .browseStart(let code): return "Bonjour browse could not start (\(code))"
        case .browseAttach: return "Bonjour browse could not attach"
        case .noService: return "No RemotePairing service is visible"
        case .resolveStart(let code): return "Bonjour resolve could not start (\(code))"
        case .resolveAttach: return "Bonjour resolve could not attach"
        case .resolveTimeout: return "Bonjour resolve timed out"
        case .resolveFailed(let code): return "Bonjour resolve failed (\(code))"
        case .metadataMissing: return "RemotePairing endpoint metadata is incomplete"
        }
    }
}

private func rpBrowseCallback(
    _ sdRef: DNSServiceRef?,
    _ flags: DNSServiceFlags,
    _ interfaceIndex: UInt32,
    _ errorCode: DNSServiceErrorType,
    _ serviceName: UnsafePointer<CChar>?,
    _ regtype: UnsafePointer<CChar>?,
    _ replyDomain: UnsafePointer<CChar>?,
    _ context: UnsafeMutableRawPointer?
) {
    guard errorCode == kDNSServiceErr_NoError,
          flags & DNSServiceFlags(kDNSServiceFlagsAdd) != 0,
          let context,
          let serviceName,
          let regtype,
          let replyDomain else { return }

    let state = Unmanaged<RPBrowseState>.fromOpaque(context).takeUnretainedValue()
    let service = RPService(
        name: String(cString: serviceName),
        type: String(cString: regtype),
        domain: String(cString: replyDomain)
    )
    let key = "\(service.name)|\(service.type)|\(service.domain)"
    state.lock.lock()
    state.services[key] = service
    state.lock.unlock()
}

private func parseRPTXT(_ data: Data) -> [String: String] {
    let bytes = [UInt8](data)
    var index = 0
    var out: [String: String] = [:]

    while index < bytes.count {
        let length = Int(bytes[index])
        index += 1
        guard length > 0, index + length <= bytes.count else { break }
        let entry = Array(bytes[index..<(index + length)])
        index += length
        guard let text = String(bytes: entry, encoding: .utf8) else { continue }

        if let split = text.firstIndex(of: "=") {
            let key = String(text[..<split])
            let value = String(text[text.index(after: split)...])
            if !key.isEmpty { out[key] = value }
        } else if !text.isEmpty {
            out[text] = ""
        }
    }
    return out
}

private func rpResolveCallback(
    _ sdRef: DNSServiceRef?,
    _ flags: DNSServiceFlags,
    _ interfaceIndex: UInt32,
    _ errorCode: DNSServiceErrorType,
    _ fullname: UnsafePointer<CChar>?,
    _ hosttarget: UnsafePointer<CChar>?,
    _ port: UInt16,
    _ txtLen: UInt16,
    _ txtRecord: UnsafePointer<UInt8>?,
    _ context: UnsafeMutableRawPointer?
) {
    guard let context else { return }
    let state = Unmanaged<RPResolveState>.fromOpaque(context).takeUnretainedValue()

    guard errorCode == kDNSServiceErr_NoError else {
        state.finish(error: RPResolverError.resolveFailed(errorCode))
        return
    }

    var fields: [String: String] = [:]
    if let txtRecord, txtLen > 0 {
        fields = parseRPTXT(Data(bytes: txtRecord, count: Int(txtLen)))
    }

    guard let identifier = fields["identifier"], !identifier.isEmpty,
          let authTag = fields["authTag"], !authTag.isEmpty else {
        state.finish(error: RPResolverError.metadataMissing)
        return
    }

    let endpoint = RemotePairingEndpoint(
        port: Int(UInt16(bigEndian: port)),
        identifier: identifier,
        authTag: authTag,
        wireProtocolVersion: fields["wireProtocolVersion"]
    )
    state.finish(endpoint: endpoint)
}

enum RemotePairingResolver {
    private static let serviceType = "_remotepairing._tcp"
    private static let domain = "local."

    static func resolveOnce() async throws -> [RemotePairingEndpoint] {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(with: Result { try resolveSynchronously() })
            }
        }
    }

    private static func resolveSynchronously() throws -> [RemotePairingEndpoint] {
        let queue = DispatchQueue(label: "com.temporary.relayone.bonjour")
        let browseState = RPBrowseState()
        var browseRef: DNSServiceRef?

        let browseCode = DNSServiceBrowse(
            &browseRef,
            0,
            0,
            serviceType,
            domain,
            rpBrowseCallback,
            Unmanaged.passUnretained(browseState).toOpaque()
        )
        guard browseCode == kDNSServiceErr_NoError, let browseRef else {
            throw RPResolverError.browseStart(browseCode)
        }
        guard DNSServiceSetDispatchQueue(browseRef, queue) == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(browseRef)
            throw RPResolverError.browseAttach
        }

        Thread.sleep(forTimeInterval: 1.5)
        DNSServiceRefDeallocate(browseRef)

        browseState.lock.lock()
        let services = Array(browseState.services.values)
        browseState.lock.unlock()
        guard !services.isEmpty else { throw RPResolverError.noService }

        var endpoints: [RemotePairingEndpoint] = []
        for service in services {
            if let endpoint = try? resolve(service, queue: queue) {
                endpoints.append(endpoint)
            }
        }
        guard !endpoints.isEmpty else { throw RPResolverError.metadataMissing }

        var unique: [String: RemotePairingEndpoint] = [:]
        for endpoint in endpoints {
            unique["\(endpoint.identifier)|\(endpoint.port)|\(endpoint.authTag)"] = endpoint
        }
        return Array(unique.values)
    }

    private static func resolve(_ service: RPService, queue: DispatchQueue) throws -> RemotePairingEndpoint {
        let state = RPResolveState()
        var resolveRef: DNSServiceRef?
        let code = DNSServiceResolve(
            &resolveRef,
            0,
            0,
            service.name,
            service.type,
            service.domain,
            rpResolveCallback,
            Unmanaged.passUnretained(state).toOpaque()
        )
        guard code == kDNSServiceErr_NoError, let resolveRef else {
            throw RPResolverError.resolveStart(code)
        }
        guard DNSServiceSetDispatchQueue(resolveRef, queue) == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(resolveRef)
            throw RPResolverError.resolveAttach
        }

        let wait = state.done.wait(timeout: .now() + 2.0)
        DNSServiceRefDeallocate(resolveRef)
        guard wait == .success else { throw RPResolverError.resolveTimeout }

        state.lock.lock()
        let endpoint = state.endpoint
        let error = state.error
        state.lock.unlock()

        if let error { throw error }
        guard let endpoint else { throw RPResolverError.metadataMissing }
        return endpoint
    }
}
