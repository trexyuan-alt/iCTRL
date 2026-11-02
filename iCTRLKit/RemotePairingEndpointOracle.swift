import Foundation
import dnssd

private struct RemotePairingService {
    let name: String
    let type: String
    let domain: String
}

private final class RemotePairingBrowseState {
    let lock = NSLock()
    var services: [String: RemotePairingService] = [:]
}

private final class RemotePairingResolveState {
    let lock = NSLock()
    var result: [String: JSONValue]?
    var error: JSONRPCError?
    let done = DispatchSemaphore(value: 0)
    var signaled = false

    func finish(result: [String: JSONValue]? = nil, error: JSONRPCError? = nil) {
        lock.lock()
        guard !signaled else { lock.unlock(); return }
        signaled = true
        self.result = result
        self.error = error
        lock.unlock()
        done.signal()
    }
}

private func remotePairingBrowseCallback(
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
          let context, let serviceName, let regtype, let replyDomain else { return }
    let state = Unmanaged<RemotePairingBrowseState>.fromOpaque(context).takeUnretainedValue()
    let service = RemotePairingService(
        name: String(cString: serviceName),
        type: String(cString: regtype),
        domain: String(cString: replyDomain)
    )
    let key = "\(service.name)|\(service.type)|\(service.domain)"
    state.lock.lock()
    state.services[key] = service
    state.lock.unlock()
}

private func parseRemotePairingTXT(_ data: Data) -> [String: String] {
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

private func remotePairingResolveCallback(
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
    let state = Unmanaged<RemotePairingResolveState>.fromOpaque(context).takeUnretainedValue()
    guard errorCode == kDNSServiceErr_NoError else {
        state.finish(error: .serverError("RemotePairing Bonjour resolve failed (\(errorCode))"))
        return
    }

    var fields: [String: String] = [:]
    if let txtRecord, txtLen > 0 {
        fields = parseRemotePairingTXT(Data(bytes: txtRecord, count: Int(txtLen)))
    }
    guard let identifier = fields["identifier"], !identifier.isEmpty,
          let authTag = fields["authTag"], !authTag.isEmpty else {
        state.finish(error: .serverError("RemotePairing endpoint metadata is incomplete"))
        return
    }

    var output: [String: JSONValue] = [
        "port": .int(Int(UInt16(bigEndian: port))),
        "identifier": .string(identifier),
        "authTag": .string(authTag),
        "service_type": .string("_remotepairing._tcp.local."),
    ]
    if let wire = fields["wireProtocolVersion"], !wire.isEmpty {
        output["wireProtocolVersion"] = .string(wire)
    }
    state.finish(result: output)
}

/// Read-only local Bonjour lookup for this device's RemotePairing TCP #1 listener.
///
/// This does not open a RemotePairing connection and performs no control action.
/// It only browses/resolves _remotepairing._tcp.local. and returns the current
/// SRV port plus selected TXT metadata. If more than one distinct service is
/// visible, it fails closed instead of guessing which device is this runner.
enum RemotePairingEndpointOracle {
    private static let serviceType = "_remotepairing._tcp"
    private static let domain = "local."

    static func resolve() -> ([String: JSONValue]?, JSONRPCError?) {
        let queue = DispatchQueue(label: "com.openminis.ictrl.remotepairing-oracle")
        let browse = RemotePairingBrowseState()
        var browseRef: DNSServiceRef?
        let browseContext = Unmanaged.passUnretained(browse).toOpaque()

        let browseError = DNSServiceBrowse(
            &browseRef, 0, 0, serviceType, domain,
            remotePairingBrowseCallback, browseContext
        )

        guard browseError == kDNSServiceErr_NoError, let browseRef else {
            return (nil, .serverError("RemotePairing Bonjour browse could not start (\(browseError))"))
        }
        guard DNSServiceSetDispatchQueue(browseRef, queue) == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(browseRef)
            return (nil, .serverError("RemotePairing Bonjour browse could not attach to dispatch queue"))
        }

        // Collect a bounded snapshot. No retry and no network connection to the
        // advertised service is made here.
        Thread.sleep(forTimeInterval: 1.5)
        DNSServiceRefDeallocate(browseRef)

        browse.lock.lock()
        let services = Array(browse.services.values)
        browse.lock.unlock()

        guard !services.isEmpty else {
            return (nil, .serverError("No _remotepairing._tcp.local. service is currently visible"))
        }
        guard services.count == 1, let service = services.first else {
            return (nil, .serverError("Multiple RemotePairing services are visible; refusing to guess the current device"))
        }

        let resolved = RemotePairingResolveState()
        var resolveRef: DNSServiceRef?
        let resolveContext = Unmanaged.passUnretained(resolved).toOpaque()
        let resolveError = DNSServiceResolve(
            &resolveRef, 0, 0, service.name, service.type, service.domain,
            remotePairingResolveCallback, resolveContext
        )

        guard resolveError == kDNSServiceErr_NoError, let resolveRef else {
            return (nil, .serverError("RemotePairing Bonjour resolve could not start (\(resolveError))"))
        }
        guard DNSServiceSetDispatchQueue(resolveRef, queue) == kDNSServiceErr_NoError else {
            DNSServiceRefDeallocate(resolveRef)
            return (nil, .serverError("RemotePairing Bonjour resolve could not attach to dispatch queue"))
        }

        let wait = resolved.done.wait(timeout: .now() + 2.0)
        DNSServiceRefDeallocate(resolveRef)
        guard wait == .success else {
            return (nil, .serverError("RemotePairing Bonjour resolve timed out"))
        }

        resolved.lock.lock()
        let result = resolved.result
        let error = resolved.error
        resolved.lock.unlock()
        return (result, error)
    }
}
