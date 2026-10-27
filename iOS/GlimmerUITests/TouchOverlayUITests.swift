// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import XCTest

@MainActor
final class TouchOverlayUITests: XCTestCase {
    override func setUp() { continueAfterFailure = false }

    func testTouchOnlyDarkPicture() { journey(light: false, large: false) }
    func testTouchOnlyLightPicture() { journey(light: true, large: false) }
    func testTouchOnlyLargestText() { journey(light: false, large: true) }

    func testTouchOnlyConnectionStatesRemainDismissible() {
        for state in ["connecting", "reconnecting", "waiting", "failure"] {
            let app = XCUIApplication()
            app.launchEnvironment["GLIMMER_UI_TESTING"] = "stream"
            app.launchEnvironment["GLIMMER_OVERLAY_STATE"] = state
            app.launch()
            XCTAssertTrue(app.buttons["Desktop"].waitForExistence(timeout: 10))
            app.buttons["Desktop"].tap()
            if state == "waiting" {
                XCTAssertTrue(app.staticTexts["Waiting for video…"].waitForExistence(timeout: 5))
                record("touch-ui-state-waiting-banner", app: app)
                XCTAssertFalse(app.staticTexts["Waiting for video…"].frame.intersects(
                    app.buttons["stream-controls-show"].frame))
                app.buttons["stream-controls-show"].tap()
            }
            let exit = app.buttons["stream-disconnect"]
            XCTAssertTrue(exit.waitForExistence(timeout: 5))
            XCTAssertTrue(exit.isHittable)
            record("touch-ui-state-" + state, app: app)
            exit.tap()
            XCTAssertTrue(app.buttons["Desktop"].waitForExistence(timeout: 10))
            app.terminate()
        }
    }

    private func journey(light: Bool, large: Bool) {
        let app = XCUIApplication()
        app.launchEnvironment["GLIMMER_UI_TESTING"] = "stream"
        app.launchEnvironment["GLIMMER_OVERLAY_PICTURE"] = light ? "light" : "dark"
        if large {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        defer { app.terminate() }
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["Desktop"].waitForExistence(timeout: 10))
        app.buttons["Desktop"].tap()
        XCTAssertTrue(app.buttons["touch-control-a"].waitForExistence(timeout: 10))
        let prefix = "touch-ui-\(light ? "light" : "dark")-\(large ? "AX5" : "normal")"
        record(prefix + "-portrait-entry", app: app)
        XCUIDevice.shared.orientation = .landscapeLeft
        let button = app.buttons["touch-control-a"]
        XCTAssertTrue(button.isHittable)
        XCTAssertGreaterThanOrEqual(button.frame.width, 44)
        button.tap()
        XCTAssertEqual(button.value as? String, "Released")
        let stick = app.otherElements["touch-control-leftStick"]
        XCTAssertTrue(stick.exists)
        stick.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1,
            thenDragTo: stick.coordinate(withNormalizedOffset: CGVector(dx: 0.85, dy: 0.5)))
        record(prefix + "-play", app: app)
        let more = app.buttons["stream-controls-show"].frame
        for id in ["touch-control-options", "touch-control-menu"] {
            XCTAssertFalse(app.buttons[id].frame.insetBy(dx: -16, dy: -40).intersects(more), id)
        }
        app.buttons["stream-controls-show"].tap()
        record(prefix + "-menu", app: app)
        let actions = app.descendants(matching: .any).matching(identifier: "stream-controls-actions").firstMatch
        if !large {
            for id in ["stream-resume", "stream-stats-toggle", "stream-edit-controls", "stream-help"] {
                XCTAssertTrue(actions.frame.contains(app.buttons[id].frame), "\(id) shows without scrolling")
            }
        }
        XCTAssertNoThrow(try app.performAccessibilityAudit(for: [.hitRegion, .sufficientElementDescription, .trait]))
        XCTAssertTrue(app.buttons["stream-disconnect"].isHittable)
        XCTAssertGreaterThanOrEqual(app.buttons["stream-disconnect"].frame.height, 44)
        reveal("stream-stats-toggle", in: app)
        app.buttons["stream-stats-toggle"].tap()
        reveal("stream-resume", in: app, backward: true)
        app.buttons["stream-resume"].tap()
        XCTAssertTrue(button.waitForExistence(timeout: 5))
        XCTAssertTrue(button.isHittable)
        let video = app.otherElements["Video from the PC"]
        XCTAssertTrue((video.value as? String)?.contains("59.9 FPS") == true)
        record(prefix + "-stats", app: app)
        app.buttons["stream-controls-show"].tap()
        reveal("stream-help", in: app)
        app.buttons["stream-help"].tap()
        XCTAssertTrue(app.buttons["stream-help-done"].waitForExistence(timeout: 5))
        let keyboardHint = app.staticTexts.containing(NSPredicate(format: "label CONTAINS %@", "Control-/"))
        XCTAssertFalse(keyboardHint.firstMatch.exists)
        record(prefix + "-help", app: app)
        app.buttons["stream-help-done"].tap()
        reveal("stream-edit-controls", in: app, backward: true)
        editControls(app, large: large, prefix: prefix, video: video)
        app.buttons["touch-editor-done"].tap()
        XCTAssertTrue(app.buttons["stream-disconnect"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["stream-disconnect"].isHittable)
        record(prefix + "-exit-menu", app: app)
        app.buttons["stream-disconnect"].tap()
        record(prefix + "-exit-result", app: app)
        XCTAssertTrue(video.waitForNonExistence(timeout: 5))
        let desktop = app.buttons["Desktop"]
        for _ in 0..<5 where !desktop.exists || !desktop.isHittable { app.swipeUp() }
        XCTAssertTrue(desktop.waitForExistence(timeout: 5))
        XCTAssertTrue(desktop.isHittable)
        record(prefix + "-disconnected", app: app)
    }

    private func editControls(_ app: XCUIApplication, large: Bool, prefix: String, video: XCUIElement) {
        app.buttons["stream-edit-controls"].tap()
        XCTAssertTrue(app.buttons["touch-editor-done"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.buttons["touch-editor-done"].isHittable)
        XCTAssertGreaterThanOrEqual(app.buttons["touch-editor-done"].frame.height, 44)
        XCTAssertGreaterThanOrEqual(app.buttons["touch-editor-cancel"].frame.height, 44)
        XCTAssertFalse((video.value as? String)?.contains("59.9 FPS") == true)
        record(prefix + "-editor", app: app)
        if !large {
            let panel = app.descendants(matching: .any).matching(identifier: "touch-editor-inspector").firstMatch
                .frame.union(app.buttons["touch-editor-done"].frame).union(app.buttons["touch-editor-reset"].frame)
            for id in ["leftShoulder", "rightShoulder", "leftTrigger", "rightTrigger", "y", "x", "b", "a", "dpad"] {
                XCTAssertFalse(app.buttons["touch-editor-\(id)"].frame.intersects(panel), "panel covers \(id)")
            }
        }
        reveal("touch-editor-reset", in: app, container: "touch-editor-inspector")
        XCTAssertNoThrow(try app.performAccessibilityAudit(for: [.hitRegion, .sufficientElementDescription, .trait]))
    }

    private func reveal(_ identifier: String, in app: XCUIApplication, backward: Bool = false,
                        container: String = "stream-controls-actions") {
        let scroll = app.descendants(matching: .any).matching(identifier: container).firstMatch
        let target = app.buttons[identifier]
        for _ in 0..<32 {
            // Menu rows scroll under the pinned Disconnect bar; a visible row ends above it.
            let inBar = ["stream-disconnect", "stream-quit"].contains(identifier)
            let floor = container != "stream-controls-actions" || inBar ? scroll.frame.maxY
                : ["stream-disconnect", "stream-quit"].map { app.buttons[$0] }.filter(\.exists)
                    .map(\.frame.minY).min() ?? scroll.frame.maxY
            if target.exists, !target.frame.intersects(scroll.frame)
                || target.frame.minY >= scroll.frame.minY && target.frame.maxY <= floor + 1, target.isHittable { break }
            let offset = target.exists ? min(40, max(-40, (scroll.frame.minY + floor) / 2 - target.frame.midY))
                : backward ? 40.0 : -40.0
            let start = scroll.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: offset)),
                        withVelocity: .slow, thenHoldForDuration: 0.15)
        }
        XCTAssertTrue(target.isHittable, identifier)
    }

    private func record(_ name: String, app: XCUIApplication) {
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        let tree = XCTAttachment(string: app.debugDescription)
        tree.name = name + "-accessibility"
        tree.lifetime = .keepAlways
        add(tree)
    }
}
