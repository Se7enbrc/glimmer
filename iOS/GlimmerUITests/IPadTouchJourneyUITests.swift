// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import XCTest

@MainActor
final class IPadTouchJourneyUITests: TouchJourneyTestCase {
    func testSplitWindowDuringPlayKeepsPictureAndTouchExit() throws {
        try XCTSkipUnless(UIDevice.current.userInterfaceIdiom == .pad, "Split View needs the iPad destination")
        let app = try launch(windowed: true)
        addTeardownBlock { @MainActor [self] in setWindowMode(windowed: false) }
        // A window that still fills the screen hides its controls; shrink it first, as a player would.
        let launcher = app.windows.firstMatch
        let corner = launcher.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.99))
        let target = launcher.coordinate(withNormalizedOffset: CGVector(dx: 0.35, dy: 0.35))
        corner.press(forDuration: 0.3, thenDragTo: target)
        let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
        let controls = system.buttons["window-controls:io.ugfugl.Glimmer.iOS"]
        XCTAssertTrue(controls.waitForExistence(timeout: 5))
        controls.tap()
        system.buttons["Zoom-button"].press(forDuration: 1)
        let arrangement = system.descendants(matching: .any)["Left and Right"].firstMatch
        XCTAssertTrue(arrangement.waitForExistence(timeout: 5))
        arrangement.tap()
        app.buttons["launcher-app-1"].firstMatch.tap()
        XCTAssertTrue(waitForReceipt("rendered"))
        XCTAssertTrue(app.staticTexts["Make this window larger to use touch controls."].firstMatch.exists)
        try assertPicture(app)
        let window = app.windows.firstMatch
        let original = window.frame
        record("ipad-split-before-resize")
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.99))
            .press(forDuration: 0.3, thenDragTo: window.coordinate(withNormalizedOffset: CGVector(dx: 1.7, dy: 0.8)))
        XCTAssertTrue(waitForReceipt("resize"), "Resizing during play must request a new PC mode")
        XCTAssertNotEqual(window.frame.size, original.size, "The live stream window must actually resize")
        XCTAssertEqual(receipts().filter { $0["launch"] == 1 }.count, 1)
        XCTAssertFalse(receipts().contains { $0["stop"] == 1 || $0["quit"] == 1 })
        XCTAssertTrue(app.buttons["A"].waitForExistence(timeout: 5))
        let index = receipts().count
        app.buttons["A"].tap()
        assertPCInput(since: index, pressed: 0x1000)
        try assertPicture(app)
        record("ipad-split-window-stream")
        stop(app)
    }
}
