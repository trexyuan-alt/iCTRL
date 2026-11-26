from pathlib import Path
import re
import unittest

ROOT = Path(__file__).resolve().parents[1]

class PrewarmSourceContract(unittest.TestCase):
    def test_native_registration_zero_parameters_no_foreground(self):
        intent = (ROOT/'iCTRLApp/Intents/PrewarmIntent.swift').read_text(encoding='utf-8-sig')
        self.assertIn('struct PrewarmIntent: ForegroundContinuableIntent', intent)
        self.assertIn('@available(iOS 16.4, *)', intent)
        self.assertEqual(intent.count('requestToContinueInForeground('), 1)
        self.assertIn('static var title: LocalizedStringResource = "PREWARM"', intent)
        self.assertIn('static var openAppWhenRun: Bool = false', intent)
        self.assertIn('static var isDiscoverable: Bool = true', intent)
        self.assertNotIn('@Parameter', intent)
        self.assertIn('struct iCTRLPrewarmShortcuts: AppShortcutsProvider', intent)
        self.assertIn('AppShortcut(intent: PrewarmIntent()', intent)
        self.assertEqual(intent.count('PrewarmIntentOperation.perform'), 1)
        self.assertEqual(intent.count('PrewarmClient.fromKeychain().submit {'), 1)
        project = (ROOT/'project.yml').read_text(encoding='utf-8-sig')
        self.assertIn('iOS: "16.0"', project)
        self.assertIn('- path: iCTRLApp', project)

    def test_shortcuts_never_own_or_return_credentials(self):
        intent = (ROOT/'iCTRLApp/Intents/PrewarmIntent.swift').read_text(encoding='utf-8-sig')
        for forbidden in ('Authorization', '.token', 'https://', '@Parameter', 'OwnerControlCredential(', 'KeychainStore'):
            self.assertNotIn(forbidden, intent)
        self.assertIn('return .result(value: state)', intent)

    def test_one_post_existing_keychain_no_hidden_actions(self):
        client = (ROOT/'iCTRLApp/Models/PrewarmClient.swift').read_text(encoding='utf-8-sig')
        self.assertEqual(client.count('session.data(for: request)'), 1)
        self.assertEqual(client.count('method: "POST", endpoint: "prewarm"'), 1)
        self.assertEqual(client.count('method: "GET", endpoint: "prewarm-status"'), 1)
        self.assertIn('static let observationDeadline: TimeInterval = 48', client)
        self.assertIn('static let foregroundThreshold: TimeInterval = 25', client)
        self.assertIn('static let observationInterval: UInt64 = 200_000_000', client)
        self.assertIn('status.triggerTimestamp == operation', client)
        self.assertIn('case .warm: return .warm', client)
        self.assertIn('case .failed: throw PrewarmProductError.canonicalFailed', client)
        self.assertIn('OwnerControlCredentialStore.load()', client)
        self.assertIn('completionHandler(nil)', client)
        for forbidden in ('.arm(', '.off(', '.service(', '.status(', '.ensure(', '.rotate(', 'Thread.sleep', 'UIApplication', 'XCTest', 'LiveActivity'):
            self.assertNotIn(forbidden, client)
        self.assertEqual(client.count('continueInForeground()'), 1)
        owner = (ROOT/'iCTRLApp/Models/OwnerControlClient.swift').read_text(encoding='utf-8-sig')
        self.assertIn('static let account = "owner-control-v2"', owner)
        self.assertIn('KeychainStore.load(account: account)', owner)

if __name__ == '__main__': unittest.main()
