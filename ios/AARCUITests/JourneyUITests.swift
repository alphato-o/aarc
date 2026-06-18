import XCTest

/// Harness B — XCUITest journey layer (the "Playwright-style" piece): drive the
/// REAL app on the simulator and screenshot key beats so layout/UX/behaviour
/// are eyeballable (agent pulls the PNGs; founder views them in ~/Downloads).
///
/// Phase 1 = prove the pipeline: launch the app (UITEST mode skips the HealthKit
/// prompt + heavy launch tasks) and capture the home screen as a kept
/// attachment. The runner is launched with -resultBundlePath so the PNGs can be
/// exported from the .xcresult afterwards.
final class JourneyUITests: XCTestCase {

    override func setUp() { continueAfterFailure = false }

    private func launchApp() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["AARC_UITEST"] = "1"
        app.launch()
        return app
    }

    private func shot(_ app: XCUIApplication, _ name: String) {
        let a = XCTAttachment(screenshot: app.screenshot())
        a.name = name
        a.lifetime = .keepAlways
        add(a)
    }

    func testLaunchHomeScreenshot() {
        let app = launchApp()
        // Wait for the UI to settle (any window element present).
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        shot(app, "01-home")
    }
}
