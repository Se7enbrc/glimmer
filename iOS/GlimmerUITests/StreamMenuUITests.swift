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
        let top = app.otherElements["Video from the PC"].coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0))
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

    func testKeyboardOpensHiddenControlsAndKeepsStopShortcut() {
        let app = launchStream(hardwareKeyboard: true)
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Show controls"].firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertTrue(app.otherElements["Video from the PC"].exists)
        app.typeKey("/", modifierFlags: .control)
        XCTAssertTrue(app.buttons["Close menu"].waitForExistence(timeout: 5))
        app.buttons["Close menu"].tap()
        XCTAssertTrue(app.otherElements["Video from the PC"].exists)
        app.typeKey("q", modifierFlags: .control)
        XCTAssertTrue(app.buttons["Desktop"].waitForExistence(timeout: 5))
    }

    private func revealMenu(_ app: XCUIApplication) {
        let menu = app.buttons["Show controls"].firstMatch
        app.otherElements["Video from the PC"].coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0))
            .withOffset(CGVector(dx: 0, dy: 22)).tap()
        XCTAssertTrue(menu.exists)
    }

    private func launchStream(hardwareKeyboard: Bool = false) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["GLIMMER_UI_TESTING"] = "stream"
        app.launch()
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["Desktop"].waitForExistence(timeout: 10))
        if hardwareKeyboard { app.connectHardwareKeyboard() }
        app.buttons["Desktop"].tap()
        XCTAssertTrue(app.otherElements["Video from the PC"].waitForExistence(timeout: 10))
        return app
    }
}

extension XCUIApplication {
    func openStreamControls() {
        if buttons["Close menu"].exists { return }
        let video = otherElements["Video from the PC"]
        XCTAssertTrue(video.waitForExistence(timeout: 10))
        if buttons["Close menu"].exists { return }
        video.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0))
            .withOffset(CGVector(dx: 0, dy: 22)).tap()
        let menu = buttons["Show controls"].firstMatch
        XCTAssertTrue(menu.exists)
        menu.tap()
        XCTAssertTrue(buttons["Close menu"].waitForExistence(timeout: 5))
    }
}
