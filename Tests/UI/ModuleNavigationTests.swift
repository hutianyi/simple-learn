import XCTest

final class ModuleNavigationTests: XCTestCase {
    func testLongPressReordersCardsAndPersistsAfterRelaunch() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["module.ji"].waitForExistence(timeout: 10))
        let cards = ["ji", "suan", "ting", "lian", "bei", "mo"].map { app.buttons["module.\($0)"] }
            .sorted { left, right in
                if abs(left.frame.minY - right.frame.minY) > 10 { return left.frame.minY < right.frame.minY }
                return left.frame.minX < right.frame.minX
            }
        let firstID = cards[0].identifier
        let secondID = cards[1].identifier
        cards[0].press(forDuration: 0.7, thenDragTo: cards[1])
        let first = app.buttons[firstID]
        let second = app.buttons[secondID]
        let moved = NSPredicate(format: "value == %@", "第 2 项，共 6 项")
        XCTAssertTrue(expectation(for: moved, evaluatedWith: first).fulfillWithin(timeout: 5))
        XCTAssertEqual(second.value as? String, "第 1 项，共 6 项")
        XCTAssertFalse(app.buttons["shell.switch"].exists, "Dragging must not open a module")

        app.terminate()
        app.launch()
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        XCTAssertEqual(first.value as? String, "第 2 项，共 6 项")
        XCTAssertEqual(second.value as? String, "第 1 项，共 6 项")
        first.tap()
        let back = app.buttons["shell.switch"]
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        back.tap()
        XCTAssertTrue(first.waitForExistence(timeout: 10))
        first.press(forDuration: 0.7, thenDragTo: second)
        XCTAssertTrue(expectation(for: NSPredicate(format: "value == %@", "第 1 项，共 6 项"),
                                  evaluatedWith: first).fulfillWithin(timeout: 5))

        let last = app.buttons[cards[5].identifier]
        first.press(forDuration: 0.7, thenDragTo: last)
        XCTAssertTrue(expectation(for: NSPredicate(format: "value == %@", "第 6 项，共 6 项"),
                                  evaluatedWith: first).fulfillWithin(timeout: 5))
        first.press(forDuration: 0.7, thenDragTo: second)
        for (index, card) in cards.enumerated() {
            XCTAssertEqual(card.value as? String, "第 \(index + 1) 项，共 6 项")
        }

        first.press(forDuration: 0.7)
        XCTAssertFalse(back.exists, "A long press without dragging must not open a module")
        first.tap()
        XCTAssertTrue(back.waitForExistence(timeout: 10))
        back.tap()
    }

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

private extension XCTestExpectation {
    func fulfillWithin(timeout: TimeInterval) -> Bool {
        XCTWaiter.wait(for: [self], timeout: timeout) == .completed
    }
}
