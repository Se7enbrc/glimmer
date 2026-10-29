// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import XCTest

extension ControllerJourneyUITests {
    func testMenuHoldRevealsControllerUsableExit() throws {
        let app = try launch()
        try play(app)
        try controller(connect: true, profile: "ps")
        let index = receipts().count
        try press("menu", duration: 1200)
        XCTAssertFalse(app.buttons["stream-resume"].exists, "Pausing must not open Glimmer's menu")
        try press("menu", duration: 2700)
        record("controller-menu-hold")
        XCTAssertTrue(receipts().dropFirst(index).contains { $0["pcButtons"] == 0x10 })
        XCTAssertTrue(app.buttons["Disconnect"].waitForExistence(timeout: 5))
        XCTAssertFalse(receipts().contains { $0["mouse"] != nil }, "Menu hold opens controls, never mouse mode")
        try controller(steps: [["element": "b", "value": 1, "route": "button", "milliseconds": 100],
                               ["element": "b", "value": 0, "route": "button"]])
        XCTAssertTrue(app.buttons["stream-resume"].waitForNonExistence(timeout: 5))
        try press("menu", duration: 2700)
        XCTAssertTrue(app.buttons["stream-resume"].waitForExistence(timeout: 5))
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.05, dy: 0.5)).tap()
        XCTAssertTrue(app.buttons["stream-resume"].waitForNonExistence(timeout: 5))
        try controller(connect: false)
        XCTAssertTrue(app.buttons["A"].waitForExistence(timeout: 5))
        stop(app)
    }

    func testPlayStationLabelsAndRecordedStopRemap() throws {
        let app = try launch()
        try controller(connect: true, profile: "ps")
        XCUIDevice.shared.orientation = .portrait
        openInputSettings(app)
        app.buttons["Controller layouts"].tap()
        let device = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Backbone One")).firstMatch
        XCTAssertTrue(device.waitForExistence(timeout: 5))
        device.tap()
        // The diagram lays out after the device page pushes; read its glyphs once they exist.
        XCTAssertTrue(app.buttons["xmark.circle"].waitForExistence(timeout: 5))
        record("playstation-controller-diagram")
        for (name, symbol) in [("Cross", "xmark.circle"), ("Circle", "circle.circle"),
                               ("Square", "square.circle"), ("Triangle", "triangle.circle")] {
            XCTAssertEqual(app.buttons[symbol].label, name, "The diagram must use PlayStation glyphs and labels")
        }
        let stopShortcut = app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", "Stop streaming")).firstMatch
        reveal(stopShortcut, in: app)
        record("stop-remap-row-visible")
        stopShortcut.tap()
        record("stop-remap-sheet")
        let recordButtons = app.buttons["Record buttons…"]
        XCTAssertTrue(app.navigationBars["Change Stop streaming"].waitForExistence(timeout: 5))
        reveal(recordButtons, in: app)
        recordButtons.tap()
        try controller(steps: [["element": "lb", "value": 1, "milliseconds": 10],
                              ["element": "ls", "value": 1, "milliseconds": 10],
                              ["element": "rs", "value": 1, "milliseconds": 600],
                              ["element": "rs", "value": 0], ["element": "ls", "value": 0],
                              ["element": "lb", "value": 0]])
        XCTAssertFalse(app.buttons["Save"].isEnabled, "An overlapping shortcut must be rejected")
        recordButtons.tap()
        try controller(steps: ["a", "b", "x"].map {
            ["element": $0, "value": 1, "milliseconds": $0 == "x" ? 600 : 10]
        } + ["x", "b", "a"].map { ["element": $0, "value": 0] })
        XCTAssertTrue(app.buttons["Save"].isEnabled)
        record("recorded-controller-stop-remap")
        app.buttons["Save"].tap()
        dismissSettings(app)
        let game = app.buttons["launcher-app-1"].firstMatch
        XCTAssertTrue(game.waitForExistence(timeout: 5))
        game.tap()
        XCTAssertTrue(waitForReceipt("rendered"))
        try controller(steps: ["lb", "rb", "options", "menu"].map {
            ["element": $0, "value": 1, "milliseconds": $0 == "menu" ? 600 : 10]
        } + ["menu", "options", "rb", "lb"].map { ["element": $0, "value": 0] })
        XCTAssertFalse(receipts().contains { $0["stop"] == 1 }, "The old chord must no longer stop")
        try controller(steps: ["a", "b", "x"].map {
            ["element": $0, "value": 1, "milliseconds": $0 == "x" ? 600 : 10]
        } + ["x", "b", "a"].map { ["element": $0, "value": 0] })
        XCTAssertTrue(waitForReceipt("stop"))
        XCTAssertTrue(game.waitForExistence(timeout: 5))
    }

    func testTwoControllersKeepIndependentSlotsAndRestoreTouch() throws {
        let app = try launch()
        try play(app)
        try controller(connect: true, profile: "ps")
        try controller(connect: true, profile: "xbox")
        XCTAssertFalse(app.buttons["A"].exists)
        XCTAssertTrue(receipts().contains { $0["pcArrival"] == 1 && $0["slot"] == 1 && $0["mask"] == 3 })
        try press("a")
        XCTAssertTrue(receipts().contains { $0["pcButtons"] == 0x1000 && $0["slot"] == 0 && $0["mask"] == 3 })
        try controller(slot: 1, steps: [["element": "x", "value": 1, "milliseconds": 100],
                                       ["element": "x", "value": 0]])
        XCTAssertTrue(receipts().contains { $0["pcButtons"] == 0x4000 && $0["slot"] == 1 && $0["mask"] == 3 })
        try controller(connect: false)
        XCTAssertFalse(app.buttons["A"].exists, "One controller remains connected")
        try press("b")
        XCTAssertTrue(receipts().contains { $0["pcButtons"] == 0x2000 && $0["slot"] == 0 && $0["mask"] == 1 })
        try controller(connect: false)
        XCTAssertTrue(app.buttons["A"].waitForExistence(timeout: 5))
        stop(app)
    }

    func testVirtualControllerReachesThePC() throws {
        let app = try launch()
        try play(app)
        try controller(connect: true)
        XCTAssertTrue(waitForReceipt("nativeControllers"))
        try press("a")
        XCTAssertTrue(waitForReceipt("pcButtons", value: 0x1000))
        XCTAssertFalse(app.buttons["A"].exists)
        try controller(connect: false)
        XCTAssertTrue(app.buttons["A"].waitForExistence(timeout: 5))
        stop(app)
    }

    func testNintendoLabelsKeepStandardButtonPositions() throws {
        let app = try launch()
        try controller(connect: true, profile: "nintendo")
        XCUIDevice.shared.orientation = .portrait
        openInputSettings(app)
        app.buttons["Controller layouts"].tap()
        let device = app.buttons.matching(NSPredicate(format: "label CONTAINS %@", "Switch Pro Controller")).firstMatch
        XCTAssertTrue(device.waitForExistence(timeout: 5))
        device.tap()
        for name in ["A", "B", "X", "Y"] {
            XCTAssertTrue(app.buttons[name].firstMatch.exists)
        }
        record("nintendo-positional-labels")
        dismissSettings(app)
        app.buttons["launcher-app-1"].firstMatch.tap()
        XCTAssertTrue(waitForReceipt("rendered"))
        for (position, mask) in [("a", 0x1000), ("b", 0x2000), ("x", 0x4000), ("y", 0x8000)] {
            let index = receipts().count
            try press(position)
            XCTAssertTrue(receipts().dropFirst(index).contains { $0["pcButtons"] == Double(mask) })
        }
        try controller(connect: false)
        stop(app)
    }

    func dismissSettings(_ app: XCUIApplication) {
        for _ in 0..<4 {
            if app.buttons["Done"].firstMatch.exists {
                app.buttons["Done"].firstMatch.tap()
                XCUIDevice.shared.orientation = .landscapeLeft
                // iOS 27 drops a tap that lands while the sheet dismisses or the window rotates.
                let window = app.windows.firstMatch
                let settled = NSPredicate { _, _ in
                    !app.buttons["Done"].exists && window.frame.width > window.frame.height
                }
                let waited = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: settled, object: nil)],
                                              timeout: 5)
                XCTAssertEqual(waited, .completed, "The library must settle in landscape")
                return
            }
            guard let back = app.navigationBars.buttons.allElementsBoundByIndex.last(where: { $0.isHittable }) else {
                XCTFail("Settings must have a reachable Back button")
                return
            }
            back.tap()
        }
        XCTFail("Settings must offer a visible route back to the library")
    }

    func reveal(_ element: XCUIElement, in app: XCUIApplication) {
        for _ in 0..<12 {
            let safeFrame = app.windows.firstMatch.frame
            if element.exists && element.isHittable && safeFrame.contains(element.frame) { return }
            guard let list = app.collectionViews.allElementsBoundByIndex.last else {
                XCTFail("The settings form must remain visible while scrolling")
                return
            }
            list.swipeUp(velocity: .slow)
        }
        XCTAssertTrue(element.isHittable)
    }
}
