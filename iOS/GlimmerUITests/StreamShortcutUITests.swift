// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import XCTest

@MainActor
final class StreamShortcutUITests: XCTestCase {
    func testDefaultChordsToggleRepeatedlyAndStop() {
        let app = launch()
        defer { app.terminate() }
        app.buttons["Desktop"].tap()
        let video = app.otherElements["Video from the PC"]
        XCTAssertTrue(video.waitForExistence(timeout: 10))
        record(app, name: "native-stats-before")
        for _ in 0..<2 {
            app.typeKey("z", modifierFlags: .control)
            XCTAssertTrue(waitForStats(video, shown: true))
            record(app, name: "native-stats-after")
            app.typeKey("z", modifierFlags: .control)
            XCTAssertTrue(waitForStats(video, shown: false))
        }
        app.typeKey("q", modifierFlags: .control)
        XCTAssertTrue(app.buttons["Desktop"].waitForExistence(timeout: 10))
    }

    func testRecordedChordAndMenuShareSessionVisibility() {
        let app = launch()
        defer { app.terminate() }
        app.buttons["Settings"].tap()
        app.buttons["Input"].tap()
        let recorder = app.buttons["Change Show or Hide Stream Stats shortcut"].firstMatch
        XCTAssertTrue(recorder.waitForExistence(timeout: 10))
        recorder.tap()
        app.typeKey("s", modifierFlags: [.control, .shift])
        XCTAssertTrue(NSPredicate(format: "value == %@", "⌃⇧S").evaluate(with: recorder))
        app.navigationBars["Input"].buttons.firstMatch.tap()
        app.buttons["Done"].tap()
        app.buttons["Desktop"].tap()
        let video = app.otherElements["Video from the PC"]
        XCTAssertTrue(video.waitForExistence(timeout: 10))
        app.typeKey("s", modifierFlags: [.control, .shift])
        XCTAssertTrue(waitForStats(video, shown: true))
        record(app, name: "native-remapped-stats-after")
        app.openStreamControls()
        record(app, name: "native-stats-with-controls-after")
        XCTAssertTrue(app.buttons["Hide stream stats"].waitForExistence(timeout: 5))
        app.buttons["Hide stream stats"].tap()
        XCTAssertTrue(waitForStats(video, shown: false))
        record(app, name: "native-stream-menu-after")
        app.buttons["Disconnect"].tap()
        XCTAssertTrue(app.buttons["Desktop"].waitForExistence(timeout: 10))
    }

    private func record(_ app: XCUIApplication, name: String) {
        let attachment = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    private func launch() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["GLIMMER_UI_TESTING"] = "stream"
        app.launch()
        XCUIDevice.shared.orientation = UIDevice.current.userInterfaceIdiom == .pad ? .portrait : .landscapeLeft
        XCTAssertTrue(app.buttons["Desktop"].waitForExistence(timeout: 10))
        app.connectHardwareKeyboard()
        return app
    }

    private func waitForStats(_ video: XCUIElement, shown: Bool) -> Bool {
        let predicate = NSPredicate { object, _ in
            guard let element = object as? XCUIElement else { return false }
            return ((element.value as? String)?.contains("59.9 FPS") == true) == shown
        }
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: video)], timeout: 5)
            == .completed
    }
}

extension XCUIApplication {
    func connectHardwareKeyboard() {
        // A literal key initializes iOS keyboard routing; modifier-only setup emits no HID events.
        typeKey("x", modifierFlags: [])
        activate()
    }
}
