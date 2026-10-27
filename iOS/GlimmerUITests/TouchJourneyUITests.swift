// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import CryptoKit
import XCTest

@MainActor
final class TouchJourneyUITests: TouchJourneyTestCase {
    func testFirstRunPairLibraryLaunchAndRender() throws {
        let app = try launch(firstRun: true)
        app.buttons["Set up a PC"].tap()
        app.buttons["PCs"].tap()
        app.buttons["Add PC by address…"].tap()
        let address = app.textFields["IP address or hostname"]
        XCTAssertTrue(address.waitForExistence(timeout: 5))
        address.tap()
        address.typeText("pc.invalid")
        app.buttons["Connect"].tap()
        let pin = app.staticTexts["Pairing PIN"]
        XCTAssertTrue(pin.waitForExistence(timeout: 5))
        let digits = (pin.value as? String ?? "").filter(\.isNumber)
        XCTAssertEqual(digits.count, 4)
        XCTAssertTrue(app.staticTexts["Enter this PIN in Sunshine on Journey PC."].exists)
        XCTAssertTrue(waitForReceipt("pairRequested"))
        // The fake PC approves only after the player has read the PIN; no PIN is persisted or attached.
        try command("approve", value: SHA256.hash(data: Data(digits.utf8)).description)
        XCTAssertTrue(waitForReceipt("paired"))
        try play(app)
        XCTAssertTrue(waitForReceipt("launch"))
        stop(app)
    }

    func testEveryButtonPressHoldReleaseAndBothSticks() throws {
        let app = try launch()
        try play(app)
        let buttons: [(String, Double)] = [
            ("A", 0x1000), ("B", 0x2000), ("X", 0x4000), ("Y", 0x8000),
            ("Left shoulder", 0x100), ("Right shoulder", 0x200),
            ("Left stick click", 0x40), ("Right stick click", 0x80), ("Options", 0x20), ("Menu", 0x10)
        ]
        for (name, mask) in buttons {
            let button = app.buttons[name]
            XCTAssertTrue(button.isHittable, "\(name) must be reachable with a finger")
            var index = receipts().count
            button.tap()
            XCTAssertEqual(samples(since: index).first?["buttons"], mask, name)
            assertNeutral(samples(since: index).last)
            assertPCInput(since: index, pressed: mask)
            index = receipts().count
            button.press(forDuration: 0.6)
            let held = samples(since: index)
            XCTAssertEqual(held.first?["buttons"], mask, name)
            XCTAssertGreaterThanOrEqual((held.last?["time"] ?? 0) - (held.first?["time"] ?? 0), 0.5)
            XCTAssertEqual(held.count, 2, "A hold must preserve the press until release")
            assertNeutral(held.last)
            assertPCInput(since: index, pressed: mask)
        }
        for (name, key) in [("Left trigger", "lt"), ("Right trigger", "rt")] {
            let index = receipts().count
            app.descendants(matching: .any)[name].firstMatch.press(forDuration: 0.6)
            XCTAssertEqual(samples(since: index).first?[key], 1)
            assertPCInput(since: index, key: key, pressed: 255)
            assertNeutral(samples(since: index).last)
        }
        for (name, key) in [("Left stick", "lx"), ("Right stick", "rx")] {
            let stick = app.descendants(matching: .any)[name].firstMatch
            let index = receipts().count
            stick.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 0.1,
                thenDragTo: stick.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.5)),
                withVelocity: .slow, thenHoldForDuration: 0.6)
            XCTAssertTrue(samples(since: index).contains { ($0[key] ?? 0) > 0.9 })
            assertPCInput(since: index, key: key, pressed: 29490)
            assertNeutral(samples(since: index).last)
            XCTAssertEqual(stick.value as? String, "Centered")
        }
        stop(app)
    }

    func testDpadDirectionsReleaseWithoutSticking() throws {
        let app = try launch()
        try play(app)
        let dpad = app.descendants(matching: .any)["Directional pad"].firstMatch
        for (x, y, mask) in [(0.5, 0.1, 1.0), (0.5, 0.9, 2.0), (0.1, 0.5, 4.0), (0.9, 0.5, 8.0)] {
            let index = receipts().count
            dpad.coordinate(withNormalizedOffset: CGVector(dx: x, dy: y)).press(forDuration: 0.6)
            XCTAssertEqual(samples(since: index).first?["buttons"], mask)
            assertPCInput(since: index, pressed: mask)
            assertNeutral(samples(since: index).last)
        }
        stop(app)
    }

    func testMenuStatsEditorOpacityCloseAndDisconnect() throws {
        let app = try launch()
        try play(app)
        openMenu(app)
        let stats = app.buttons["stream-stats-toggle"]
        stats.tap()
        XCTAssertEqual(stats.label, "Hide stream stats")
        XCTAssertTrue((app.otherElements["Video from the PC"].value as? String)?.contains("10.0 FPS") == true)
        record("stats-visible")
        stats.tap()
        XCTAssertFalse((app.otherElements["Video from the PC"].value as? String)?.contains("FPS") == true)
        app.buttons["Edit controls…"].tap()
        let opacity = app.sliders["Opacity"]
        XCTAssertTrue(opacity.waitForExistence(timeout: 5))
        opacity.adjust(toNormalizedSliderPosition: 0.8)
        let savedOpacity = opacity.value as? String
        record("edit-opacity")
        app.buttons["Done"].tap()
        XCTAssertTrue(app.buttons["stream-resume"].waitForExistence(timeout: 5))
        app.buttons["Edit controls…"].tap()
        XCTAssertEqual(opacity.value as? String, savedOpacity)
        app.buttons["Done"].tap()
        app.buttons["stream-resume"].tap()
        XCTAssertTrue(app.buttons["A"].waitForExistence(timeout: 5))
        XCTAssertFalse(receipts().contains { $0["stop"] == 1 }, "X closes only the menu")
        try assertPicture(app)
        stop(app)
        XCTAssertTrue(receipts().contains { $0["quit"] == 1 }, "Default disconnect quits the game")
    }

    func testTouchOnlyCanAlwaysStopAfterRotationAndBackground() throws {
        let app = try launch()
        try play(app)
        XCUIDevice.shared.orientation = .landscapeRight
        XCTAssertTrue(app.buttons["Show controls"].firstMatch.waitForExistence(timeout: 5))
        try assertPicture(app)
        XCUIDevice.shared.press(.home)
        XCTAssertTrue(app.wait(for: .runningBackground, timeout: 5))
        app.activate()
        XCTAssertTrue(app.buttons["A"].waitForExistence(timeout: 10))
        app.buttons["A"].tap()
        assertNeutral(receipts().last { $0["buttons"] != nil })
        stop(app)
    }

    func testControllerArrivalAndRemovalRestoresTouchPlay() throws {
        let app = try launch()
        try play(app)
        try command("controller", value: "connect")
        XCTAssertTrue(waitForReceipt("controller"))
        XCTAssertTrue(app.buttons["A"].waitForNonExistence(timeout: 5))
        let menu = app.buttons["Show controls"].firstMatch
        XCTAssertTrue(menu.waitForNonExistence(timeout: 5))
        let video = app.otherElements["Video from the PC"]
        let top = video.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.04))
        top.press(forDuration: 0.05, thenDragTo: video.coordinate(withNormalizedOffset: CGVector(dx: 0.25, dy: 0.25)))
        XCTAssertTrue(menu.exists, "The revealed menu must be present before its two-second timeout")
        try command("controller", value: "disconnect")
        XCTAssertTrue(waitForReceipt("controller", value: 0))
        XCTAssertTrue(app.buttons["A"].waitForExistence(timeout: 5))
        let index = receipts().count
        app.buttons["A"].tap()
        XCTAssertEqual(samples(since: index).first?["buttons"], 0x1000)
        assertNeutral(samples(since: index).last)
        stop(app)
    }

    func testLeaveRunningDisconnectOffersResume() throws {
        let app = try launch()
        XCTAssertTrue(app.buttons["launcher-app-1"].firstMatch.waitForExistence(timeout: 10))
        app.buttons["Settings"].tap()
        app.buttons["General"].tap()
        let leaveRunning = app.switches["Leave games running when you disconnect"]
        XCTAssertTrue(leaveRunning.waitForExistence(timeout: 5))
        XCTAssertEqual(leaveRunning.value as? String, "0")
        leaveRunning.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.5)).tap()
        XCTAssertEqual(XCTWaiter.wait(for: [XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "value == %@", "1"), object: leaveRunning)], timeout: 3), .completed)
        record("leave-running-enabled")
        app.navigationBars["General"].buttons.firstMatch.tap()
        app.buttons["Done"].tap()
        try play(app)
        stop(app)
        XCTAssertTrue(receipts().contains { $0["stop"] == 1 && $0["quit"] == 0 })
        let resume = app.buttons["launcher-app-1"].firstMatch
        XCTAssertTrue(resume.waitForExistence(timeout: 5))
        XCTAssertTrue(resume.label.contains("Resume stream"))
        record("resume-after-disconnect")
        resume.tap()
        XCTAssertTrue(waitForReceipt("resume"))
        XCTAssertTrue(app.buttons["A"].waitForExistence(timeout: 10))
        try assertPicture(app)
        stop(app)
    }

    func testOverlayAccessibilityLabels() throws {
        let app = try launch()
        try play(app)
        let names = ["Left stick", "Right stick", "Directional pad", "A", "B", "X", "Y",
                     "Left shoulder", "Right shoulder", "Left trigger", "Right trigger",
                     "Left stick click", "Right stick click", "Options", "Menu", "Show controls"]
        for name in names {
            let element = app.descendants(matching: .any)[name].firstMatch
            XCTAssertEqual(element.label, name)
            XCTAssertTrue(element.isHittable, "\(name) must be accessible on screen")
        }
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .trait])
        let ordered = app.descendants(matching: .any).allElementsBoundByIndex.filter { names.contains($0.label) }
        XCTAssertEqual(Set(ordered.map(\.label)), Set(names), "Every overlay control belongs to the accessibility tree")
        let traversal = ordered.map(\.label).filter { $0 != "Show controls" }
        openMenu(app)
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .trait])
        for id in ["stream-stats-toggle", "stream-controller-layouts", "stream-edit-controls", "stream-disconnect",
                   "stream-resume"] {
            XCTAssertTrue(app.buttons[id].isHittable)
            XCTAssertFalse(app.buttons[id].label.isEmpty)
        }
        app.buttons["Edit controls…"].tap()
        XCTAssertTrue(app.sliders["Opacity"].isHittable)
        try app.performAccessibilityAudit(for: [.sufficientElementDescription, .trait])
        app.buttons["Done"].tap()
        app.buttons["stream-resume"].tap()
        let restored = app.descendants(matching: .any).allElementsBoundByIndex.map(\.label)
            .filter { names.contains($0) && $0 != "Show controls" }
        XCTAssertEqual(restored, traversal, "Closing overlays must restore the gamepad's accessibility traversal order")
        stop(app)
    }

    func testLargestTextKeepsOverlayActionsReachable() throws {
        let app = try launch(largeText: true)
        try play(app)
        openMenu(app)
        record("largest-text-menu")
        let window = app.windows.firstMatch.frame
        // Every action is on screen or scrolls into view; Disconnect never scrolls away.
        for id in ["stream-resume", "stream-stats-toggle", "stream-edit-controls", "stream-controller-layouts",
                   "stream-help", "stream-quit", "stream-disconnect"] {
            let control = scrolledIntoView(id, in: app)
            XCTAssertTrue(control.isHittable, "Largest text must leave \(id) reachable")
            XCTAssertTrue(window.contains(control.frame), "\(id) must not clip outside the window")
            XCTAssertTrue(app.buttons["stream-disconnect"].isHittable)
        }
        scrolledIntoView("stream-resume", in: app).tap()
        stop(app)
    }

    private func scrolledIntoView(_ id: String, in app: XCUIApplication) -> XCUIElement {
        let control = app.buttons[id]
        let list = app.descendants(matching: .any).matching(identifier: "stream-controls-actions").firstMatch
        // Rows scroll under the pinned Disconnect bar, so a visible row ends above it.
        let floor = id == "stream-disconnect" ? list.frame.maxY : app.buttons["stream-disconnect"].frame.minY
        func visible() -> Bool { list.frame.contains(control.frame) && control.frame.maxY <= floor + 1 }
        for _ in 0..<12 where !visible() || !control.isHittable {
            let start = list.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5))
            let offset = max(-60, min(60, (list.frame.minY + floor) / 2 - control.frame.midY))
            start.press(forDuration: 0.05, thenDragTo: start.withOffset(CGVector(dx: 0, dy: offset)),
                        withVelocity: .slow, thenHoldForDuration: 0.1)
        }
        return control
    }
}
