import SwiftUI

@main
struct RelayOneApp: App {
    @StateObject private var coordinator = CompanionCoordinator()

    private var buildRevision: String {
        (Bundle.main.object(forInfoDictionaryKey: "RelayOneBuildRevision") as? String)
            .flatMap { $0.isEmpty ? nil : $0 } ?? "unknown"
    }

    var body: some Scene {
        WindowGroup {
            VStack(spacing: 14) {
                ProgressView()
                Text(coordinator.status)
                    .font(.headline)
                    .multilineTextAlignment(.center)
                if !coordinator.detail.isEmpty {
                    Text(coordinator.detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                Text("Build 2 · \(buildRevision)")
                    .font(.caption2.monospaced())
                    .foregroundStyle(.secondary)
            }
            .padding(28)
            .task {
                coordinator.startOnce()
            }
        }
    }
}
