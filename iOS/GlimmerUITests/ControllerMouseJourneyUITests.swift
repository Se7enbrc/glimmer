// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import XCTest

extension ControllerJourneyUITests {
    func testRightHandedMouseAndControllerRecordedClickRemap() throws {
        try mouseJourney(leftHanded: false, remap: true)
    }

    func testLeftHandedMousePresetMatchesItsLabels() throws {
        try mouseJourney(leftHanded: true, remap: false)
    }

    private func mouseJourney(leftHanded: Bool, remap: Bool) throws {
        let app = try launch()
        try controller(connect: true, profile: "xbox")
        XCUIDevice.shared.orientation = .portrait
        app.buttons["Settings"].tap()
        app.buttons["Input"].tap()
        let mouse = button(startingWith: "Controller mouse", in: app)
        reveal(mouse, in: app)
        mouse.tap()
        if leftHanded {
            button(startingWith: "Preset", in: app).tap()
            app.buttons["Left-handed"].tap()
        }
        let hand = leftHanded ? "Left-handed" : "Right-handed"
        XCTAssertEqual(button(startingWith: "Preset", in: app).value as? String, hand)
        record("controller-mouse-" + hand)
        if remap {
            let click = button(startingWith: "Primary click", in: app)
            reveal(click, in: app)
            click.tap()
            let recording = app.buttons["Record buttons…"]
            reveal(recording, in: app)
            recording.tap()
            try press("up", duration: 600)
            XCTAssertTrue(app.buttons["Save"].isEnabled)
            app.buttons["Save"].tap()
        }
        dismissSettings(app)
        app.buttons["launcher-app-1"].firstMatch.tap()
        XCTAssertTrue(waitForReceipt("rendered"))
        try press("menu", duration: 1200)
        XCTAssertTrue(app.staticTexts["Controller is now a mouse."].exists)
        try checkMouseMotion(leftHanded: leftHanded)
        let primary = remap ? "up" : leftHanded ? "lt" : "rt"
        let clicks: [(String, Double)] = [(primary, 1), (leftHanded ? "lb" : "rb", 3),
            (leftHanded ? "ls" : "rs", 2), (leftHanded ? "rt" : "lt", 4), (leftHanded ? "rb" : "lb", 5)]
        for (element, button) in clicks {
            let index = receipts().count
            try press(element)
            let received = receipts().dropFirst(index).filter { $0["pcMouseButton"] == button }
            XCTAssertEqual(received.map { $0["action"] }, [7, 8],
                           element + " must press and release its labelled click")
        }
        if remap {
            let index = receipts().count
            try press("rt")
            XCTAssertFalse(receipts().dropFirst(index).contains { $0["pcMouseButton"] == 1 })
        }
        try press("menu", duration: 1200)
        XCTAssertTrue(app.staticTexts["Controller is back in the game."].exists)
        let index = receipts().count
        try press("a")
        XCTAssertTrue(receipts().dropFirst(index).contains { $0["pcButtons"] == 0x1000 })
        try controller(connect: false)
        stop(app)
    }

    private func checkMouseMotion(leftHanded: Bool) throws {
        var index = receipts().count
        let pointer = leftHanded ? "left" : "right"
        try controller(steps: [["element": pointer, "value": 0.75, "y": 0, "milliseconds": 250],
                              ["element": pointer, "value": 0, "y": 0]])
        XCTAssertTrue(receipts().dropFirst(index).contains { ($0["pcDX"] ?? 0) > 0 })
        index = receipts().count
        let scroll = leftHanded ? "right" : "left"
        try controller(steps: [["element": scroll, "value": 0, "y": 0.75, "milliseconds": 250],
                              ["element": scroll, "value": 0, "y": 0]])
        XCTAssertTrue(receipts().dropFirst(index).contains { ($0["pcScroll"] ?? 0) > 0 })
    }

    private func button(startingWith prefix: String, in app: XCUIApplication) -> XCUIElement {
        app.buttons.matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }
}
