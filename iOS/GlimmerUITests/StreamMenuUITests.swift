// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import XCTest

@MainActor
final class StreamMenuUITests: XCTestCase {
    func testMenuHidesAndTopEdgeGesturesRevealIt() {
        let app = launchStream()
        defer { app.terminate() }
        let menu = app.buttons["Show controls"].firstMatch
        XCTAssertTrue(menu.waitForNonExistence(timeout: 5))
        let top = app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0))
            .withOffset(CGVector(dx: 0, dy: 22))
        top.tap()
        XCTAssertTrue(menu.exists)
        XCTAssertTrue(menu.isHittable)
        XCTAssertTrue(menu.waitForNonExistence(timeout: 5))
        top.press(forDuration: 0.05, thenDragTo: top.withOffset(CGVector(dx: 0, dy: 90)))
        XCTAssertTrue(menu.exists)
        XCTAssertTrue(menu.isHittable)
        XCTAssertTrue(app.otherElements["Video from the PC"].exists)
    }

    func testCloseMenuKeepsPlayingAndDisconnectEndsTheStream() {
        let app = launchStream()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Show controls"].firstMatch.waitForNonExistence(timeout: 5))
        revealMenu(app)
        app.buttons["Show controls"].firstMatch.tap()
        let close = app.buttons["Close menu"]
        XCTAssertTrue(close.waitForExistence(timeout: 3))
        guard close.exists else { return }
        close.tap()
        XCTAssertTrue(close.waitForNonExistence(timeout: 3))
        XCTAssertTrue(app.otherElements["Video from the PC"].exists)
        XCTAssertTrue(app.buttons["Show controls"].firstMatch.waitForNonExistence(timeout: 5))
        revealMenu(app)
        app.buttons["Show controls"].firstMatch.tap()
        let disconnect = app.buttons["Disconnect"]
        XCTAssertTrue(disconnect.waitForExistence(timeout: 3))
        XCTAssertTrue(disconnect.isHittable)
        disconnect.tap()
        XCTAssertTrue(app.buttons["Desktop"].waitForExistence(timeout: 5))
        XCTAssertFalse(app.otherElements["Video from the PC"].exists)
    }

    private func revealMenu(_ app: XCUIApplication) {
        let menu = app.buttons["Show controls"].firstMatch
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0))
            .withOffset(CGVector(dx: 0, dy: 22)).tap()
        XCTAssertTrue(menu.exists)
    }

    private func launchStream() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["GLIMMER_UI_TESTING"] = "stream"
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["Desktop"].waitForExistence(timeout: 10))
        app.buttons["Desktop"].tap()
        XCTAssertTrue(app.otherElements["Video from the PC"].waitForExistence(timeout: 10))
        return app
    }
}
