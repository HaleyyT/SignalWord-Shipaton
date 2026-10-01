import XCTest

/// Uses the existing simulator-only service boundary: never sends real emails.
@MainActor
final class SignalWordLayoutTests: XCTestCase {
    private var app: XCUIApplication!
    private func launch(_ arguments: [String] = []) {
        continueAfterFailure = false
        XCUIDevice.shared.orientation = .portrait
        app = XCUIApplication()
        app.launchArguments = ["--ui-testing", "--reset-ui-state", "--ui-layout-ready"] + arguments
        app.launch()
        XCTAssertTrue(app.buttons["navigation.Home"].waitForExistence(timeout: 8))
        XCTAssertFalse(app.tabBars.firstMatch.exists, "Only one navigation bar may be present")
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5))
        XCTAssertGreaterThan(app.frame.height, app.frame.width)
    }
    private func capture(_ name: String) {
        let shot = XCTAttachment(screenshot: app.screenshot())
        shot.name = name; shot.lifetime = .keepAlways; add(shot)
    }
    private func reveal(_ element: XCUIElement) {
        let scroll = app.scrollViews.firstMatch
        // AX5 Settings spans more than 24 compact half-page pans.
        for _ in 0..<60 {
            let viewport = scroll.frame.intersection(app.frame)
            let top = viewport.minY + 4
            let bottom = min(viewport.maxY, app.buttons["navigation.Home"].frame.minY) - 4
            let bounds = CGRect(x: viewport.minX, y: top, width: viewport.width, height: max(0, bottom - top))
            let frame = element.exists ? element.frame : .zero
            let hasFrame = !frame.isEmpty
            // Resolve hittability only inside the viewport: XCTest can throw
            // for an offscreen activation point. A zero frame is unknown
            // geometry, not evidence that the footer is above the viewport.
            if hasFrame && bounds.contains(frame) && element.isHittable { return }
            let upward = !hasFrame || frame.maxY > bottom
            let overflow = !hasFrame ? bounds.height / 2 : upward ? frame.maxY - bottom : top - frame.minY
            // Use the measured overflow near the target. A fixed half-page
            // swipe oscillates past tall accessibility labels in both directions.
            let distance = min(bounds.height / 2, max(30, overflow + 8))
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: upward ? 0.8 : 0.2))
            start.press(forDuration: 0.02,
                        thenDragTo: start.withOffset(CGVector(dx: 0, dy: upward ? -distance : distance)),
                        withVelocity: .slow, thenHoldForDuration: 0.15)
        }
        capture("unreachable-control")
        print(app.debugDescription)
        XCTFail("Control must remain fully reachable: \(element)")
    }
    private func assertFooter(_ id: String) {
        let footer = app.staticTexts[id]
        reveal(footer)
        XCTAssertLessThanOrEqual(footer.frame.maxY, app.buttons["navigation.Home"].frame.minY + 1, "Final text must scroll fully above navigation")
        XCTAssertGreaterThanOrEqual(footer.frame.minX, 0)
        XCTAssertLessThanOrEqual(footer.frame.maxX, app.frame.width)
    }
    func testMainScreensHelpAndBottomReachability() {
        launch()
        let tabs = app.buttons["navigation.Home"]
        XCTAssertGreaterThan(tabs.frame.maxY, app.frame.height * 0.85, "Native tabs must use the modern full-height viewport")
        XCTAssertTrue(app.buttons["home.test"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["home.help"].isHittable, "Guide must be discoverable without scrolling")
        capture("01-home-ready")
        app.buttons["home.help"].tap()
        XCTAssertTrue(app.buttons["help.done"].waitForExistence(timeout: 5))
        capture("02-help-sheet")
        app.swipeUp()
        app.swipeUp()
        capture("03-help-details")
        app.buttons["help.done"].tap()
        assertFooter("home.footer"); capture("04-home-bottom")
        app.buttons["navigation.People"].tap()
        capture("05-people")
        assertFooter("people.footer"); capture("06-people-bottom")
        app.buttons["navigation.Settings"].tap()
        capture("07-settings")
        app.buttons["settings.help"].tap()
        XCTAssertTrue(app.buttons["help.done"].waitForExistence(timeout: 5))
        app.buttons["help.done"].tap()
        assertFooter("settings.footer"); capture("08-settings-bottom")
    }
    func testAccessibilityTextAndLongName() {
        launch(["--ui-testing-largest-text", "--ui-long-name"])
        capture("09-accessibility-home")
        let help = app.buttons["home.help"]
        reveal(help); help.tap()
        XCTAssertTrue(app.buttons["help.done"].waitForExistence(timeout: 5))
        XCTAssertGreaterThan(app.staticTexts["A phrase. A person. A way to reach them."].frame.height, 100, "Help must inherit accessibility text size")
        capture("10-accessibility-help")
        app.buttons["help.done"].tap()
        assertFooter("home.footer")
        app.buttons["navigation.People"].tap()
        capture("11-accessibility-people")
        assertFooter("people.footer")
        app.buttons["navigation.Settings"].tap()
        assertFooter("settings.footer"); capture("12-accessibility-settings-bottom")
    }
    func testTestAlertIsDistinctAndResolutionWorks() {
        launch()
        app.buttons["home.test"].tap()
        XCTAssertTrue(app.staticTexts["TEST alert active"].waitForExistence(timeout: 5))
        capture("13-test-active")
        let review = app.buttons["alert.resolve.review"]
        reveal(review); review.tap()
        let confirm = app.buttons["Resolve alert"].firstMatch
        XCTAssertTrue(confirm.waitForExistence(timeout: 5)); confirm.tap()
        XCTAssertTrue(app.buttons["home.test"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["alert.resolve"].exists)
        capture("14-test-resolved")
    }
    func testScrollingOverRealControlDoesNotSend() {
        launch()
        let control = app.buttons["alert.trigger"]
        reveal(control)
        control.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            .press(forDuration: 0.02,
                   thenDragTo: app.scrollViews.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.15)),
                   withVelocity: .slow, thenHoldForDuration: 0.15)
        XCTAssertFalse(app.buttons["alert.resolve"].exists, "Scrolling must cancel the REAL hold")
        assertFooter("home.footer")
    }
    func testPendingContactAndRecoveryFailureDoNotLookReady() {
        launch(["--ui-contact-pending"])
        XCTAssertFalse(app.buttons["home.test"].exists)
        XCTAssertFalse(app.buttons["alert.trigger"].exists)
        capture("15-confirmation-pending")
        app.terminate()
        launch(["--ui-recovery-failure"])
        XCTAssertTrue(app.buttons["home.prepare"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.buttons["home.test"].exists)
        capture("16-recovery-failure")
    }
    func testEditorKeyboardAndCancellationPreserveContact() {
        launch()
        app.buttons["navigation.People"].tap()
        let replace = app.buttons["Replace recipient"]
        reveal(replace); replace.tap()
        let email = app.textFields["name@example.com"]
        XCTAssertTrue(email.waitForExistence(timeout: 5)); email.tap()
        capture("17-contact-keyboard")
        XCTAssertTrue(app.buttons["Cancel"].isHittable)
        app.buttons["Cancel"].tap()
        XCTAssertTrue(app.staticTexts["Hoa"].firstMatch.waitForExistence(timeout: 5))
    }
    func testLandscapeNavigationAndHelpRemainReachable() {
        launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        capture("18-landscape-home")
        let help = app.buttons["home.help"]
        reveal(help); help.tap()
        XCTAssertTrue(app.buttons["help.done"].waitForExistence(timeout: 5))
        capture("19-landscape-help")
        app.buttons["help.done"].tap()
        app.buttons["navigation.Settings"].tap()
        assertFooter("settings.footer")
    }
}
