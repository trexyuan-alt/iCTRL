import SwiftUI

@main
struct RelayOneApp: App {
    @StateObject private var coordinator = CompanionCoordinator()

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
            }
            .padding(28)
            .task {
                coordinator.startOnce()
            }
        }
    }
}
