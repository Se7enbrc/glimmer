// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AppKit
import XCTest

@MainActor
final class MacControllerJourneyUITests: XCTestCase {
    private var directory = FileManager.default.temporaryDirectory
    private var sequence = 0
    private let app = XCUIApplication()

    private func launch() throws {
        continueAfterFailure = false
        XCTAssertFalse(NSWorkspace.shared.isVoiceOverEnabled, "Journeys must remain silent")
        // A signed runner is sandboxed, so the host's storage tripwire rejects its receipt folder.
        try XCTSkipIf(FileManager.default.temporaryDirectory.path.contains("/Library/Containers/"),
                      "Mac journeys need a runner that shares the host's temporary folder; harness follow-up")
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        app.launchEnvironment["GLIMMER_UI_TESTING"] = "journey"
        app.launchEnvironment["GLIMMER_JOURNEY_DIRECTORY"] = directory.path
        app.launchEnvironment["JOURNEY_APPEARANCE"] = ProcessInfo.processInfo.environment["JOURNEY_APPEARANCE"] ?? "light"
        app.launch()
        addTeardownBlock { @MainActor [self] in
            record("mac-final-state")
            if let data = try? Data(contentsOf: directory.appendingPathComponent("receipts.json")) {
                let attachment = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
                attachment.name = "fake-pc-receipts"
                attachment.lifetime = .keepAlways
                add(attachment)
            }
            app.terminate()
            try? FileManager.default.removeItem(at: directory)
        }
        XCTAssertTrue(waitForReceipt("fixture"))
        XCTAssertTrue(app.buttons["Journey game"].waitForExistence(timeout: 10))
    }

    private func receipts() -> [[String: Double]] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("receipts.json")),
              let result = try? JSONSerialization.jsonObject(with: data) as? [[String: Double]] else { return [] }
        return result
    }

    private func waitForReceipt(_ key: String, value: Double = 1) -> Bool {
        let predicate = NSPredicate { [self] _, _ in receipts().contains { $0[key] == value } }
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: 10) == .completed
    }

    private func controller(connect: Bool? = nil, profile: String = "xbox", slot: Int = 0, steps: [[String: Any]] = []) throws {
        sequence += 1
        var command: [String: Any] = ["id": sequence, "steps": steps, "profile": profile, "slot": slot]
        if let connect { command["connect"] = connect }
        try JSONSerialization.data(withJSONObject: command)
            .write(to: directory.appendingPathComponent("gamecontroller.json"), options: .atomic)
        XCTAssertTrue(waitForReceipt("command", value: Double(sequence)))
        XCTAssertFalse(receipts().contains { $0["controllerError"] != nil })
    }

    private func press(_ element: String, duration: Int = 100) throws {
        if element == "up" {
            try controller(steps: [["element": "dpad", "value": 0, "y": 1, "milliseconds": duration],
                                   ["element": "dpad", "value": 0, "y": 0]])
            return
        }
        try controller(steps: [["element": element, "value": 1, "milliseconds": duration],
                               ["element": element, "value": 0]])
    }

    private func record(_ name: String) {
        for attachment in [XCTAttachment(screenshot: app.screenshot()), XCTAttachment(string: app.debugDescription)] {
            attachment.name = name
            attachment.lifetime = .keepAlways
            add(attachment)
        }
    }

    func testControllerOnlyLaunchAndStop() throws {
        try launch()
        try controller(connect: true)
        try controller(steps: [["element": "dpad", "value": 1, "y": 0, "milliseconds": 100],
                               ["element": "dpad", "value": 0, "y": 0]])
        record("mac-launcher-controller-focus")
        try press("a")
        XCTAssertTrue(waitForReceipt("launch"))
        XCTAssertTrue(waitForReceipt("rendered"))
        try assertPicture()
        record("mac-controller-stream")
        let index = receipts().count
        try press("a", duration: 600)
        XCTAssertTrue(receipts().dropFirst(index).contains { $0["pcButtons"] == 0x1000 })
        XCTAssertEqual(receipts().last { $0["pcButtons"] != nil }?["pcButtons"], 0)
        try controller(steps: ["lb", "rb", "options", "menu"].map {
            ["element": $0, "value": 1, "milliseconds": $0 == "menu" ? 600 : 10]
        } + ["menu", "options", "rb", "lb"].map { ["element": $0, "value": 0] })
        XCTAssertTrue(waitForReceipt("stop"))
        XCTAssertTrue(waitForReceipt("quit"))
        XCTAssertTrue(app.buttons["Journey game"].isHittable)
    }

    func testPlayStationAllInputsAndPartialChords() throws {
        try streamInputs(profile: "ps")
    }

    func testXboxAllInputsAndPartialChords() throws {
        try streamInputs(profile: "xbox")
    }

    func testNintendoPositionalInputs() throws {
        try streamInputs(profile: "nintendo")
    }

    private func streamInputs(profile: String) throws {
        try launch()
        app.buttons["Journey game"].click()
        XCTAssertTrue(waitForReceipt("rendered"))
        try assertPicture()
        try controller(connect: true, profile: profile)
        let checks = JourneyInputAssertions(receipts: receipts, send: { try self.controller(steps: $0) })
        try checks.digital()
        try checks.analog()
        try checks.dpad()
        try checks.partialChord()
        record("mac-" + profile + "-input")
        try chord(["lb", "rb", "options", "menu"])
        XCTAssertTrue(waitForReceipt("quit"))
        XCTAssertTrue(app.buttons["Journey game"].waitForExistence(timeout: 10))
    }

    func testTwoControllersDisconnectIndependently() throws {
        try launch()
        app.buttons["Journey game"].click()
        XCTAssertTrue(waitForReceipt("rendered"))
        try assertPicture()
        try controller(connect: true, profile: "ps")
        try controller(connect: true, profile: "xbox")
        XCTAssertTrue(waitForReceipt("mask", value: 3))
        try press("a")
        try controller(slot: 1, steps: [["element": "x", "value": 1, "milliseconds": 600],
                                       ["element": "x", "value": 0]])
        XCTAssertTrue(receipts().contains { $0["slot"] == 0 && $0["pcButtons"] == 0x1000 })
        XCTAssertTrue(receipts().contains { $0["slot"] == 1 && $0["pcButtons"] == 0x4000 })
        try controller(connect: false)
        try press("b")
        XCTAssertTrue(receipts().contains { $0["slot"] == 0 && $0["mask"] == 1 && $0["pcButtons"] == 0x2000 })
        record("mac-one-controller-remains")
        try chord(["lb", "rb", "options", "menu"])
        XCTAssertTrue(waitForReceipt("quit"))
        XCTAssertTrue(app.buttons["Journey game"].waitForExistence(timeout: 10))
    }

    func testControllerContextActionsAndBack() throws {
        try launch()
        try controller(connect: true)
        try controller(steps: [["element": "left", "value": 1, "y": 0, "milliseconds": 100],
                               ["element": "left", "value": 0, "y": 0]])
        try press("menu")
        XCTAssertTrue(app.menus.firstMatch.waitForExistence(timeout: 5))
        record("mac-controller-context-actions")
        try press("b")
        XCTAssertTrue(app.menus.firstMatch.waitForNonExistence(timeout: 5))
        XCTAssertFalse(receipts().contains { $0["launch"] == 1 })
        try press("a")
        XCTAssertTrue(waitForReceipt("rendered"))
        try assertPicture()
        try chord(["lb", "rb", "options", "menu"])
        XCTAssertTrue(waitForReceipt("quit"))
    }

    func testStatsChordTogglesVisibleOverlay() throws {
        try launch()
        app.buttons["Journey game"].click()
        XCTAssertTrue(waitForReceipt("rendered"))
        try controller(connect: true)
        XCTAssertFalse(app.staticTexts["Render"].exists)
        try chord(["lb", "rb", "ls", "rs"])
        XCTAssertTrue(app.staticTexts["Render"].waitForExistence(timeout: 5))
        record("mac-controller-stats")
        try chord(["lb", "rb", "ls", "rs"])
        XCTAssertTrue(app.staticTexts["Render"].waitForNonExistence(timeout: 5))
        try press("a")
        XCTAssertTrue(waitForReceipt("pcButtons", value: 0x1000))
        try chord(["lb", "rb", "options", "menu"])
        XCTAssertTrue(waitForReceipt("quit"))
    }

    func testRightHandedMouseWithRecordedClickRemap() throws {
        try mouseJourney(leftHanded: false, remap: true)
    }

    func testLeftHandedMouseMatchesLabels() throws {
        try mouseJourney(leftHanded: true, remap: false)
    }

    private func mouseJourney(leftHanded: Bool, remap: Bool) throws {
        try launch()
        try controller(connect: true)
        let settings = openInputSettings()
        let mouse = control("Controller mouse")
        reveal(mouse)
        mouse.click()
        if leftHanded {
            control("Preset").click()
            app.menuItems["Left-handed"].click()
        }
        XCTAssertEqual(control("Preset").value as? String, leftHanded ? "Left-handed" : "Right-handed")
        record("mac-controller-mouse-preset")
        if remap {
            let click = control("Primary click")
            reveal(click)
            click.click()
            let recording = app.buttons["Record buttons…"]
            reveal(recording)
            recording.click()
            try press("up", duration: 600)
            XCTAssertTrue(app.buttons["Save"].isEnabled)
            app.buttons["Save"].click()
        }
        settings.buttons[XCUIIdentifierCloseWindow].click()
        app.buttons["Journey game"].click()
        XCTAssertTrue(waitForReceipt("rendered"))
        try assertPicture()
        try press("menu", duration: 1200)
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "is now a mouse.")).firstMatch.exists)
        record("mac-controller-mouse-active")
        let index = receipts().count
        let pointer = leftHanded ? "left" : "right"
        let scroll = leftHanded ? "right" : "left"
        try controller(steps: [["element": pointer, "value": 0.75, "y": 0, "milliseconds": 250],
                               ["element": pointer, "value": 0, "y": 0],
                               ["element": scroll, "value": 0, "y": 0.75, "milliseconds": 250],
                               ["element": scroll, "value": 0, "y": 0]])
        XCTAssertTrue(receipts().dropFirst(index).contains { ($0["pcDX"] ?? 0) > 0 })
        XCTAssertTrue(receipts().dropFirst(index).contains { ($0["pcScroll"] ?? 0) > 0 })
        let primary = remap ? "up" : leftHanded ? "lt" : "rt"
        for (element, button) in [(primary, 1.0), (leftHanded ? "lb" : "rb", 3),
            (leftHanded ? "ls" : "rs", 2), (leftHanded ? "rt" : "lt", 4), (leftHanded ? "rb" : "lb", 5)] {
            let index = receipts().count
            try press(element)
            let clicks = receipts().dropFirst(index).filter { $0["pcMouseButton"] == button }
            XCTAssertEqual(clicks.map { $0["action"] }, [7, 8])
        }
        if remap {
            let index = receipts().count
            try press("rt")
            XCTAssertFalse(receipts().dropFirst(index).contains { $0["pcMouseButton"] == 1 })
        }
        try press("menu", duration: 1200)
        XCTAssertTrue(app.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "back in the game.")).firstMatch.exists)
        try press("a")
        XCTAssertTrue(waitForReceipt("pcButtons", value: 0x1000))
        try chord(["lb", "rb", "options", "menu"])
        XCTAssertTrue(waitForReceipt("quit"))
    }

    func testPlayStationGlyphLabelsAndRecordedStopRemap() throws {
        try launch()
        try controller(connect: true, profile: "ps")
        let settings = openInputSettings()
        let layouts = app.buttons["Controller layouts"]
        reveal(layouts)
        layouts.click()
        control("Backbone One").click()
        for (name, symbol) in [("Cross", "xmark.circle"), ("Circle", "circle.circle"),
                               ("Square", "square.circle"), ("Triangle", "triangle.circle")] {
            XCTAssertEqual(app.buttons[symbol].label, name)
        }
        record("mac-playstation-labels")
        let stop = control("Stop streaming")
        reveal(stop)
        stop.click()
        let recording = app.buttons["Record buttons…"]
        reveal(recording)
        recording.click()
        try chord(["lb", "ls", "rs"])
        XCTAssertTrue(app.buttons["Save"].isEnabled)
        app.buttons["Save"].click()
        settings.buttons[XCUIIdentifierCloseWindow].click()
        app.buttons["Journey game"].click()
        XCTAssertTrue(waitForReceipt("rendered"))
        try assertPicture()
        try chord(["lb", "rb", "options", "menu"])
        XCTAssertFalse(receipts().contains { $0["stop"] == 1 })
        try chord(["lb", "ls", "rs"])
        XCTAssertTrue(waitForReceipt("quit"))
        XCTAssertTrue(app.buttons["Journey game"].waitForExistence(timeout: 10))
    }

    private func openInputSettings() -> XCUIElement {
        app.buttons["Settings"].click()
        let input = app.staticTexts["Input"].firstMatch
        XCTAssertTrue(input.waitForExistence(timeout: 5))
        input.click()
        return app.windows.containing(.staticText, identifier: "Input").firstMatch
    }

    private func control(_ prefix: String) -> XCUIElement {
        app.descendants(matching: .any).matching(NSPredicate(format: "label BEGINSWITH %@", prefix)).firstMatch
    }

    private func reveal(_ element: XCUIElement) {
        for _ in 0..<12 {
            if element.exists && element.isHittable { return }
            guard let scroll = app.scrollViews.allElementsBoundByIndex.last else {
                XCTFail("Settings must offer a scrollable route to the control")
                return
            }
            scroll.scroll(byDeltaX: 0, deltaY: -scroll.frame.height / 2)
        }
        XCTAssertTrue(element.isHittable)
    }

    private func assertPicture() throws {
        let window = app.windows.matching(NSPredicate(format: "label CONTAINS %@", "Journey game")).firstMatch
        XCTAssertTrue(window.waitForExistence(timeout: 5))
        let image = try XCTUnwrap(window.screenshot().image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        JourneyPicture.assertColors(image)
    }

    private func chord(_ elements: [String]) throws {
        try controller(steps: elements.enumerated().map { index, element in
            ["element": element, "value": 1, "milliseconds": index == elements.count - 1 ? 600 : 10]
        } + elements.reversed().map { ["element": $0, "value": 0] })
    }
}
