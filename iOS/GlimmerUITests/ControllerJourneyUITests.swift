// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import XCTest

@MainActor
final class ControllerJourneyUITests: TouchJourneyTestCase {
    private var sequence = 0

    func controller(connect: Bool? = nil, profile: String? = nil, slot: Int = 0, steps: [[String: Any]] = []) throws {
        sequence += 1
        var command: [String: Any] = ["id": sequence, "steps": steps, "slot": slot]
        if let connect { command["connect"] = connect }
        if let profile { command["profile"] = profile }
        let data = try JSONSerialization.data(withJSONObject: command)
        try data.write(to: directory.appendingPathComponent("gamecontroller.json"), options: .atomic)
        XCTAssertTrue(waitForReceipt("command", value: Double(sequence)), "GameController must deliver the command")
        XCTAssertFalse(receipts().contains { $0["controllerError"] != nil })
    }

    func press(_ element: String, duration: Int = 100) throws {
        if element == "up" {
            try controller(steps: [["element": "dpad", "value": 0, "y": 1, "milliseconds": duration],
                                   ["element": "dpad", "value": 0, "y": 0]])
            return
        }
        try controller(steps: [["element": element, "value": 1, "milliseconds": duration],
                               ["element": element, "value": 0]])
    }

    func testControllerOnlyLaunchAndStopChord() throws {
        let app = try launch()
        XCTAssertTrue(app.buttons["launcher-app-1"].firstMatch.waitForExistence(timeout: 10))
        try controller(connect: true)
        for (x, y) in [(1, 0), (0, -1), (-1, 0), (0, 1)] {
            try controller(steps: [["element": "dpad", "value": x, "y": y, "milliseconds": 100],
                                   ["element": "dpad", "value": 0, "y": 0]])
        }
        try controller(steps: [["element": "left", "value": 0, "y": -1, "milliseconds": 100],
                               ["element": "left", "value": 0, "y": 0]])
        record("controller-launcher-focus")
        try press("a")
        record("controller-launch-result")
        // CJ99-04: library focus is UIKit's controller navigation, which a GCVirtualController cannot drive.
        XCTExpectFailure("CJ99-04: a virtual controller cannot move UIKit focus; needs a hardware check") {
            XCTAssertTrue(waitForReceipt("launch", timeout: 2), "The focused game must launch using A without touch")
        }
        if !receipts().contains(where: { $0["launch"] != nil }) { app.buttons["launcher-app-1"].firstMatch.tap() }
        XCTAssertTrue(waitForReceipt("rendered"))
        XCTAssertFalse(app.buttons["A"].exists, "A connected controller must hide the touch gamepad")
        try assertPicture(app)
        try controller(steps: ["lb", "rb", "options", "menu"].map {
            ["element": $0, "value": 1, "milliseconds": $0 == "menu" ? 600 : 10]
        } + ["menu", "options", "rb", "lb"].map { ["element": $0, "value": 0] })
        XCTAssertTrue(waitForReceipt("stop"), "The virtual controller's Stop chord must end the stream")
        XCTAssertTrue(app.buttons["launcher-app-1"].firstMatch.waitForExistence(timeout: 5))
    }

    func testPlayStationInputAndStopChord() throws {
        let app = try launch()
        try play(app)
        try controller(connect: true, profile: "ps")
        XCTAssertTrue(waitForReceipt("nativeControllers"))
        XCTAssertFalse(app.buttons["A"].exists)
        try inputChecks.digital()
        try inputChecks.dpad()
        try inputChecks.analog()
        try assertPicture(app)
        let chordStart = receipts().count
        try controller(steps: ["lb", "rb", "options", "menu"].map {
            ["element": $0, "value": 1, "milliseconds": $0 == "menu" ? 600 : 10,
             "route": $0 == "menu" ? "button" : "profile"]
        } + ["menu", "options", "rb", "lb"].map {
            ["element": $0, "value": 0, "route": $0 == "menu" ? "button" : "profile"]
        })
        record("controller-stop-chord")
        XCTAssertTrue(waitForReceipt("stop"))
        XCTAssertFalse(receipts().dropFirst(chordStart).contains { Int($0["pcButtons"] ?? 0) & 0x330 == 0x330 },
                       "The complete Stop chord must never reach the PC")
        XCTAssertTrue(app.buttons["launcher-app-1"].firstMatch.waitForExistence(timeout: 5))
    }

    func testXboxInputStatsAndPartialChords() throws {
        let app = try launch()
        try play(app)
        try controller(connect: true, profile: "xbox")
        XCTAssertTrue(waitForReceipt("nativeControllers"))
        try inputChecks.digital()
        try inputChecks.dpad()
        try inputChecks.analog()
        try inputChecks.partialChord()
        XCTAssertFalse((app.otherElements["Video from the PC"].value as? String)?.contains("FPS") == true)
        XCTAssertFalse(receipts().contains { $0["stop"] == 1 })
        try controller(steps: ["lb", "rb", "ls", "rs"].map {
            ["element": $0, "value": 1, "milliseconds": $0 == "rs" ? 600 : 10]
        } + ["rs", "ls", "rb", "lb"].map { ["element": $0, "value": 0] })
        record("controller-stats-chord")
        XCTAssertTrue((app.otherElements["Video from the PC"].value as? String)?.contains("10.0 FPS") == true)
        try controller(connect: false)
        XCTAssertTrue(app.buttons["A"].waitForExistence(timeout: 5))
        stop(app)
    }

    private var inputChecks: JourneyInputAssertions {
        JourneyInputAssertions(receipts: receipts, send: { try self.controller(steps: $0) })
    }
}
