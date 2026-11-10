// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AppKit
import XCTest

extension MacControllerJourneyUITests {
    func testMiniPlayerTopEdgeMovesWithoutRecapturingInput() throws {
        try checkWindowDragging(miniPlayer: true)
    }

    func testWindowTopEdgeMovesWithoutRecapturingInput() throws {
        try checkWindowDragging(miniPlayer: false)
    }

    private func checkWindowDragging(miniPlayer: Bool) throws {
        try launch(captureSystemKeys: true, presentation: miniPlayer ? "cover" : "window")
        app.buttons["Journey game"].click()
        XCTAssertTrue(waitForReceipt("rendered"))
        if miniPlayer { app.typeKey("m", modifierFlags: .control) }
        app.typeKey("p", modifierFlags: [.control, .shift])
        let window = app.windows["journey-stream-window"]
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let notice = app.otherElements.matching(NSPredicate(
            format: "label BEGINSWITH %@", "Keyboard and mouse released.")).firstMatch
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        if !miniPlayer {
            let width = window.frame.width
            let corner = window.coordinate(withNormalizedOffset: CGVector(dx: 1, dy: 1))
                .withOffset(CGVector(dx: -2, dy: -2))
            corner.press(forDuration: 0.1, thenDragTo: corner.withOffset(CGVector(dx: -240, dy: -135)))
            XCTAssertLessThan(window.frame.width, width - 150)
            XCTAssertTrue(notice.exists)
        }
        let displacement: CGFloat = miniPlayer ? -60 : 60
        for background in [false, true] {
            if background {
                let finder = XCUIApplication(bundleIdentifier: "com.apple.finder")
                finder.activate()
                XCTAssertTrue(finder.wait(for: .runningForeground, timeout: 5))
            }
            let before = window.frame
            let buttons = receipts().filter { $0["pcMouseButton"] != nil }.count
            let start = window.coordinate(withNormalizedOffset: .zero)
                .withOffset(CGVector(dx: before.width / 2, dy: 16))
            record("mac-window-before-drag-\(miniPlayer)-\(background)")
            start.press(forDuration: 0.1, thenDragTo: start.withOffset(CGVector(dx: displacement, dy: 0)))
            XCTAssertEqual(window.frame.minX, before.minX + displacement, accuracy: 5)
            XCTAssertEqual(window.frame.minY, before.minY, accuracy: 5)
            XCTAssertEqual(window.frame.width, before.width, accuracy: 1)
            XCTAssertEqual(window.frame.height, before.height, accuracy: 1)
            XCTAssertEqual(receipts().filter { $0["pcMouseButton"] != nil }.count, buttons)
            XCTAssertTrue(notice.exists)
            try assertPicture()
            record("mac-window-after-drag-\(miniPlayer)-\(background)")
        }
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
        XCTAssertTrue(notice.waitForNonExistence(timeout: 5))
        let keys = receipts().filter { $0["keyboardEvent"] != nil }.count
        app.typeKey("w", modifierFlags: [])
        XCTAssertGreaterThan(receipts().filter { $0["keyboardEvent"] != nil }.count, keys)
        app.typeKey("p", modifierFlags: [.control, .shift])
        XCTAssertTrue(notice.waitForExistence(timeout: 5))
        record("mac-window-drag-and-recapture-\(miniPlayer)")
    }
}
