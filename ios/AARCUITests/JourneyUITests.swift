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

    private func launchApp(simulate: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["AARC_UITEST"] = "1"
        if simulate { app.launchEnvironment["AARC_UITEST_SIMULATE"] = "1" }
        // Force phone-only tracking (no watch on the sim). `-key value` launch
        // args land in UserDefaults, which @AppStorage reads.
        app.launchArguments += ["-aarc.trackingSource", "phone"]
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
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        shot(app, "01-home")
    }

    /// The critical journey: home → slide to start a (simulated) treadmill run →
    /// live-run screen → End → post-run summary. Screenshots each beat.
    func testTreadmillRunJourney() {
        let app = launchApp(simulate: true)
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 20))
        shot(app, "01-home")

        // Start the run via the UI-test-only start button (the real start path;
        // synthetic drags don't reliably drive the custom slide-to-start
        // gesture, and the slide mechanics aren't what this journey screenshots).
        let start = app.buttons["uitestStartTreadmill"].firstMatch
        XCTAssertTrue(start.waitForExistence(timeout: 10), "uitest start button not found")
        start.tap()

        // Live-run screen: End control appears once the run is active.
        let endRun = app.descendants(matching: .any)["endRun"].firstMatch
        XCTAssertTrue(endRun.waitForExistence(timeout: 20), "live-run End control never appeared")
        // Let a little (sped-up) distance accrue so the cockpit shows real numbers.
        Thread.sleep(forTimeInterval: 4)
        shot(app, "02-live-run")

        // End the run → confirm → summary.
        endRun.tap()
        let confirm = app.alerts.buttons["End"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5), "End-confirm alert never appeared")
        confirm.tap()

        // Post-run summary fullScreenCover.
        Thread.sleep(forTimeInterval: 3)
        shot(app, "03-summary")
    }
}
