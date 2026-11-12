import XCTest
import Foundation

final class iCTRLNonUITests: XCTestCase {
    private var server: NonUIJSONRPCServer?

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    func testStartServer() throws {
        // This target intentionally contains NO XCUIApplication, XCUIElement,
        // XCUIDevice, accessibility snapshots, or UI automation calls.
        let server = NonUIJSONRPCServer(port: 8200)
        self.server = server
        try server.start()

        print("NON_UI_XCTRUNNER_TEST_STARTED")
        print("XCTCONTAINSUITESTS_EXPECTED=NO")
        print("UI_AUTOMATION_API_USED=NO")

        // Preserve the old Runner experiment shape: one test owns the server and
        // deliberately never returns. Network work runs on its own queue while
        // this RunLoop keeps the XCTest test process alive.
        while true {
            RunLoop.current.run(until: Date(timeIntervalSinceNow: 1.0))
        }
    }
}
