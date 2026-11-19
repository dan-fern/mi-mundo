import XCTest

/// Three smoke flows through the real UI. The app is launched with
/// `-uiTesting` (fresh in-memory store); `-uiTestSeed` adds a parent, a kid
/// and a one-country quiz about France (see UITestLaunch.swift).
@MainActor
final class MiMundoUITests: XCTestCase {
    private let patient: TimeInterval = 30

    override func setUp() {
        continueAfterFailure = false
    }

    private func launch(seeded: Bool) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchArguments = ["-uiTesting"] + (seeded ? ["-uiTestSeed"] : [])
        app.launch()
        return app
    }

    private func tap(_ element: XCUIElement, file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertTrue(element.waitForExistence(timeout: patient), "Missing: \(element)", file: file, line: line)
        element.tap()
    }

    private func enterPIN(_ pin: String, in app: XCUIApplication) {
        for digit in pin { tap(app.buttons[String(digit)]) }
    }

    /// Seeded app → kid home → today's quiz → France's first question.
    private func startQuiz(_ app: XCUIApplication) {
        tap(app.buttons["Kit"])
        tap(app.buttons["Play today's quiz"])
        tap(app.buttons["Find one for me"])
    }

    /// Answers the name and capital questions of the seeded quiz correctly.
    private func answerNameAndCapital(_ app: XCUIApplication) {
        tap(app.buttons["France"])
        tap(app.buttons["Next question"])
        tap(app.buttons["Paris"])
        tap(app.buttons["Next question"])
    }

    // 1. First run: parent, then a kid, then the kid's home.
    func testFirstRunCreatesParentAndKidAndReachesKidHome() {
        let app = launch(seeded: false)

        let parentName = app.textFields["Your name"]
        tap(parentName)
        parentName.typeText("Pat")
        tap(app.buttons["Next"])
        enterPIN("1234", in: app) // choose
        enterPIN("1234", in: app) // confirm

        tap(app.buttons["Add a kid"])
        let kidName = app.textFields["Kid's name"]
        tap(kidName)
        kidName.typeText("Kit")
        tap(app.buttons["Add"])
        XCTAssertTrue(app.staticTexts["Kit"].waitForExistence(timeout: patient))

        tap(app.buttons["Switch player"])
        tap(app.buttons["Kit"])
        // Kid home, not parent home (which also shows "Kit" and "Switch
        // player"): the "Days played" gauge only kid home has, and no parent controls.
        let gauge = app.descendants(matching: .any).matching(
            NSPredicate(format: "label == 'Days played'")).firstMatch
        XCTAssertTrue(gauge.waitForExistence(timeout: patient), "Expected kid home's days-played gauge")
        XCTAssertFalse(app.buttons["Add a kid"].exists, "Parent home is still showing")
        XCTAssertTrue(app.buttons["Switch player"].exists)
    }

    // 2. A kid answers name, capital and a flag picked from four.
    func testKidPlaysOneCountryAndSeesPoints() {
        let app = launch(seeded: true)
        startQuiz(app)
        answerNameAndCapital(app)

        tap(app.buttons["Pick it from four instead (half points)"])
        let flags = app.buttons.matching(NSPredicate(format: "label BEGINSWITH 'Flag '"))
        XCTAssertTrue(flags.element(boundBy: 3).waitForExistence(timeout: patient), "Expected four flags")
        XCTAssertEqual(flags.count, 4)
        flags.element(boundBy: 0).tap()
        tap(app.buttons["Done"])

        // The summary: "+N points" (full for name and capital, plus half or 0 for the flag).
        let points = app.staticTexts.matching(NSPredicate(format: "label MATCHES %@", "\\+[0-9]+ points")).firstMatch
        XCTAssertTrue(points.waitForExistence(timeout: patient), "Summary should show the points")
        let earned = Int(points.label.dropFirst().prefix { $0.isNumber }) ?? -1
        XCTAssertGreaterThanOrEqual(earned, 20, "Name + capital are 10 points each")
    }

    // 3. The freehand pad: open, draw, "Check my flag" visible and tappable.
    func testFreehandPadCheckButtonIsVisibleAndTappable() {
        let app = launch(seeded: true)
        startQuiz(app)
        answerNameAndCapital(app)

        tap(app.buttons["Start drawing"])
        let canvas = app.otherElements["Drawing canvas"]
        XCTAssertTrue(canvas.waitForExistence(timeout: patient))
        canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.2, dy: 0.5))
            .press(forDuration: 0.1, thenDragTo: canvas.coordinate(withNormalizedOffset: CGVector(dx: 0.8, dy: 0.5)))

        let check = app.buttons["Check my flag"]
        XCTAssertTrue(check.waitForExistence(timeout: patient))
        XCTAssertTrue(check.isHittable, "The button must be on screen, not clipped by the card")
        // isHittable only needs the centre on screen: the whole button must be
        // inside the window and clear of the canvas.
        let window = app.windows.firstMatch.frame
        XCTAssertTrue(window.contains(check.frame), "Button \(check.frame) is clipped by the window \(window)")
        XCTAssertFalse(check.frame.intersects(canvas.frame), "Button overlaps the drawing canvas")
        XCTAssertTrue(check.isEnabled)
        check.tap()

        // Checking returns to the card, with a verdict and a way on.
        XCTAssertTrue(app.buttons["Done"].waitForExistence(timeout: patient))
        XCTAssertFalse(check.exists)
    }
}
