#if canImport(AppIntents)
import AppIntents

@available(iOS 16.4, *)
struct PrewarmIntent: ForegroundContinuableIntent {
    static var title: LocalizedStringResource = "PREWARM"
    static var description = IntentDescription("Trigger canonical PREWARM once and remain active until factual WARM. FAILED or unconfirmed completion stops the intent.")
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = true

    func perform() async throws -> some IntentResult & ReturnsValue<String> {
        let state = try await PrewarmIntentOperation.perform {
            try await PrewarmClient.fromKeychain().submit {
                try await requestToContinueInForeground("PREWARM is still running. Continue in iCTRL to finish the same operation.")
            }
        }
        return .result(value: state)
    }
}

@available(iOS 16.4, *)
struct iCTRLPrewarmShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: PrewarmIntent(), phrases: ["PREWARM with \(.applicationName)"],
                    shortTitle: "PREWARM", systemImageName: "bolt.fill")
    }
}
#endif
