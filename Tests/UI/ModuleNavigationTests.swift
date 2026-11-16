import XCTest

final class ModuleNavigationTests: XCTestCase {
    func testSimpleJiPagesKeepBottomNavigationWhenSwitchingDirectly() {
        let app = XCUIApplication()
        app.launch()
        defer { XCUIDevice.shared.orientation = .portrait }
        let entry = app.buttons["module.ji"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()

        let pages = ["study", "wordLibrary", "statistics", "settings"]
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            for selected in pages + pages.reversed() {
                let button = app.buttons["ji.page.\(selected)"]
                XCTAssertTrue(button.waitForExistence(timeout: 10))
                button.tap()
                XCTAssertTrue(expectation(for: NSPredicate(format: "selected == true"),
                    evaluatedWith: button).fulfillWithin(timeout: 5))
                let viewport = app.windows.firstMatch.frame
                for page in pages {
                    let destination = app.buttons["ji.page.\(page)"]
                    XCTAssertTrue(destination.isHittable, "Every main page must allow direct switching")
                    XCTAssertGreaterThan(destination.frame.minY, viewport.midY)
                    XCTAssertLessThanOrEqual(destination.frame.maxY, viewport.maxY)
                }
            }
        }
    }

    func testHomeOverviewAndAllSixCardsFitPortraitAndLandscape() {
        let app = XCUIApplication()
        app.launch()
        defer { XCUIDevice.shared.orientation = .portrait }
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(app.buttons["module.ji"].waitForExistence(timeout: 10))
            let viewport = app.windows.firstMatch.frame
            XCTAssertFalse(app.buttons["module.bei"].exists)
            if orientation == .portrait { XCTAssertLessThan(viewport.width, viewport.height) }
            else { XCTAssertGreaterThan(viewport.width, viewport.height) }
            for module in ["ji", "suan", "du", "ting", "lian", "mo"] {
                let card = app.buttons["module.\(module)"]
                XCTAssertTrue(card.exists)
                XCTAssertTrue(card.isHittable)
                XCTAssertGreaterThanOrEqual(card.frame.minY, viewport.minY)
                XCTAssertLessThanOrEqual(card.frame.maxY, viewport.maxY, "Every card should fit without scrolling")
            }
            let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
            screenshot.name = orientation == .portrait ? "首页竖屏" : "首页横屏"
            screenshot.lifetime = .keepAlways
            add(screenshot)
            XCTAssertLessThan(app.buttons["home.overview.ji"].frame.minX, app.buttons["home.overview.suan"].frame.minX)
            XCTAssertLessThan(app.buttons["home.overview.suan"].frame.minX, app.buttons["home.overview.lian"].frame.minX)
            for module in ["ji", "suan", "lian"] {
                let overview = app.buttons["home.overview.\(module)"]
                XCTAssertTrue(overview.isHittable)
                overview.tap()
                let back = app.buttons["shell.switch"]
                XCTAssertTrue(back.waitForExistence(timeout: 10))
                back.tap()
            }
        }
    }

    func testListenImportImmediatelyUpdatesArticleLibrary() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launch()
        let entry = app.buttons["module.ting"]
        XCTAssertTrue(entry.waitForExistence(timeout: 10))
        entry.tap()

        for _ in 0..<2 {
            let title = "Library Refresh \(UUID().uuidString)"
            app.buttons["listen.import"].tap()
            let editor = app.textViews["listen.importText"]
            XCTAssertTrue(editor.waitForExistence(timeout: 5))
            editor.tap()
            editor.typeText("# Article 1: \(title)\n\nThis is a sample article for the import refresh test.")
            app.buttons["listen.confirmImport"].tap()
            XCTAssertTrue(expectation(for: NSPredicate(format: "exists == false"),
                                      evaluatedWith: editor).fulfillWithin(timeout: 10))
            let row = app.buttons.containing(.staticText, identifier: title).firstMatch
            XCTAssertTrue(row.waitForExistence(timeout: 5), "The imported article must appear without leaving SimpleTing")
            XCTAssertTrue(row.isHittable, "The newest article must be visible in the sidebar")
        }
    }

    func testListenArticleEndStaysAbovePlayerAfterScrollingStops() {
        XCUIDevice.shared.orientation = .landscapeLeft
        defer { XCUIDevice.shared.orientation = .portrait }
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["module.ting"].waitForExistence(timeout: 10))
        app.buttons["module.ting"].tap()
        app.buttons["listen.import"].tap()
        let editor = app.textViews["listen.importText"]
        XCTAssertTrue(editor.waitForExistence(timeout: 5))
        let finalParagraph = "The final paragraph must remain fully visible after releasing the scroll. These last sentences belong above the player, including this final line."
        let paragraphs = (1...18).map {
            "Paragraph \($0). This is a long reading passage. Each paragraph takes several lines so the article needs scrolling in both portrait and landscape."
        }.joined(separator: "\n\n")
        editor.tap()
        editor.typeText("# Article 1: Scroll Boundary Test\n\n\(paragraphs)\n\n\(finalParagraph)")
        app.buttons["listen.confirmImport"].tap()
        XCTAssertTrue(expectation(for: NSPredicate(format: "exists == false"), evaluatedWith: editor).fulfillWithin(timeout: 10))

        for orientation in [UIDeviceOrientation.landscapeLeft, .portrait] {
            XCUIDevice.shared.orientation = orientation
            let body = app.scrollViews["listen.articleBody"]
            let player = app.otherElements["listen.player"]
            XCTAssertTrue(body.waitForExistence(timeout: 5))
            XCTAssertTrue(player.waitForExistence(timeout: 5))
            let end = body.staticTexts[finalParagraph]
            for _ in 0..<20 {
                body.swipeUp()
                if end.exists, end.frame.minY >= body.frame.minY, end.frame.maxY <= body.frame.maxY { break }
            }
            // Push past the end once more, then check the settled position after the drag releases.
            body.swipeUp()
            XCTAssertTrue(end.exists)
            XCTAssertLessThanOrEqual(body.frame.maxY, player.frame.minY + 1, "The scroll viewport must end above the entire player")
            for _ in 0..<3 {
                XCTAssertGreaterThanOrEqual(end.frame.minY, body.frame.minY)
                XCTAssertLessThanOrEqual(end.frame.maxY, body.frame.maxY, "All final lines must remain visible after overscroll settles")
                XCTAssertLessThanOrEqual(end.frame.maxY, player.frame.minY)
                // Screenshot capture also allows the UI to settle between position checks.
                let screenshot = XCTAttachment(screenshot: app.screenshot())
                screenshot.name = "文章末尾松手后-\(orientation.rawValue)"
                screenshot.lifetime = .keepAlways
                add(screenshot)
            }
        }
    }

    func testLongPressReordersCardsAndPersistsAfterRelaunch() {
        let app = XCUIApplication()
        app.launch()
        XCTAssertTrue(app.buttons["module.ji"].waitForExistence(timeout: 10))
        let cards = ["ji", "suan", "du", "ting", "lian", "mo"].map { app.buttons["module.\($0)"] }
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
        app.buttons["home.overview.ji"].tap()
        XCTAssertTrue(back.waitForExistence(timeout: 10), "Overview must still open after reordering")
        back.tap()
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
