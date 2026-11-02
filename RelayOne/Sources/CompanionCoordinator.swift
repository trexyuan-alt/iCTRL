import Foundation
import UIKit

@MainActor
final class CompanionCoordinator: ObservableObject {
    @Published var status = "Checking endpoint…"
    @Published var detail = ""

    private var started = false

    func startOnce() {
        guard !started else { return }
        started = true

        Task {
            do {
                status = "Resolving local endpoint…"
                let endpoints = try await RemotePairingResolver.resolveOnce()

                let credentials = try CredentialStore.loadOrCreate()
                let client = RenderClient(credentials: credentials)

                status = "Checking Render…"
                try await client.register()
                let cache = try await client.state()

                let selected = try selectEndpoint(endpoints, cache: cache)

                if cache?.port == selected.port {
                    status = "Endpoint unchanged"
                    openChatGPT()
                    return
                }

                status = "Updating Render…"
                try await client.publish(selected)

                status = "Render acknowledged"
                openChatGPT()
            } catch {
                status = "Endpoint check failed"
                detail = error.localizedDescription
            }
        }
    }

    private func selectEndpoint(
        _ endpoints: [RemotePairingEndpoint],
        cache: RenderEndpointCache?
    ) throws -> RemotePairingEndpoint {
        if let cached = cache {
            if let match = endpoints.first(where: { $0.identifier == cached.identifier }) {
                return match
            }
            if let match = endpoints.first(where: { $0.port == cached.port }) {
                return match
            }
        }

        if endpoints.count == 1, let only = endpoints.first {
            return only
        }

        throw NSError(
            domain: "RelayOne.EndpointSelection",
            code: 1,
            userInfo: [NSLocalizedDescriptionKey: "Multiple RemotePairing services are visible and none matches the last confirmed Render endpoint"]
        )
    }

    private func openChatGPT() {
        guard let appURL = URL(string: "chatgpt://"),
              let webURL = URL(string: "https://chatgpt.com/") else {
            status = "ChatGPT launch URL unavailable"
            return
        }

        UIApplication.shared.open(appURL, options: [:]) { success in
            if !success {
                UIApplication.shared.open(webURL, options: [:], completionHandler: nil)
            }
        }
    }
}
