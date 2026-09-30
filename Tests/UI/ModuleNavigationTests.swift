import XCTest

final class ModuleNavigationTests: XCTestCase {
    func testEachModuleCanOpenAndReturnHome() {
        let app = XCUIApplication()
        app.launch()
        for module in ["ji", "mo", "suan", "lian", "ting", "bei"] {
            let entry = app.buttons["module.\(module)"]
            XCTAssertTrue(entry.waitForExistence(timeout: 10))
            entry.tap()
            let button = app.buttons["shell.switch"]
            XCTAssertTrue(button.waitForExistence(timeout: 10))
            XCTAssertTrue(button.isEnabled)
            button.tap()
        }
    }
}
