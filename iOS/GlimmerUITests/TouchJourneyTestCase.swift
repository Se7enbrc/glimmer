// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import XCTest

@MainActor
class TouchJourneyTestCase: XCTestCase {
    var directory = FileManager.default.temporaryDirectory
    var application: XCUIApplication?

    override func setUp() {
        continueAfterFailure = false
        let speaking = MainActor.assumeIsolated { UIAccessibility.isVoiceOverRunning }
        XCTAssertFalse(speaking, "Journey tests require VoiceOver off and silent fixtures")
    }

    func finishJourney() {
        record("journey-final-state")
        if let data = try? Data(contentsOf: directory.appendingPathComponent("receipts.json")) {
            let receipt = XCTAttachment(data: data, uniformTypeIdentifier: "public.json")
            receipt.name = "fake-pc-receipts"
            receipt.lifetime = .keepAlways
            add(receipt)
        }
        application?.terminate()
        application = nil
        if directory != FileManager.default.temporaryDirectory { try? FileManager.default.removeItem(at: directory) }
        XCUIDevice.shared.orientation = .portrait
    }

    func launch(firstRun: Bool = false, largeText: Bool = false, windowed: Bool = false) throws -> XCUIApplication {
        if UIDevice.current.userInterfaceIdiom == .pad {
            XCUIDevice.shared.orientation = windowed ? .portrait : .landscapeLeft
            setWindowMode(windowed: windowed)
        }
        directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let app = XCUIApplication()
        app.launchEnvironment["GLIMMER_UI_TESTING"] = firstRun ? "journey-first" : "journey"
        app.launchEnvironment["GLIMMER_JOURNEY_DIRECTORY"] = directory.path
        if largeText {
            app.launchArguments += ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        application = app
        addTeardownBlock { @MainActor [self] in finishJourney() }
        XCUIDevice.shared.orientation = windowed ? .portrait : .landscapeLeft
        XCTAssertTrue(waitForReceipt("fixture"))
        return app
    }

    func setWindowMode(windowed: Bool) {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.activate()
        let multitasking = settings.buttons["Multitasking & Gestures"]
        XCTAssertTrue(multitasking.waitForExistence(timeout: 5))
        multitasking.tap()
        let name = windowed ? "windowedApps" : "fullScreenApps"
        let option = settings.descendants(matching: .any)
            .matching(identifier: "com.apple.settings.multitaskingAndGestures." + name).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.tap()
    }

    func play(_ app: XCUIApplication) throws {
        let game = app.buttons["launcher-app-1"].firstMatch
        XCTAssertTrue(game.waitForExistence(timeout: 10))
        game.tap()
        XCTAssertTrue(app.otherElements["Video from the PC"].waitForExistence(timeout: 10))
        XCTAssertTrue(waitForReceipt("rendered"), "The sample-buffer display layer must present a frame")
        XCTAssertEqual(receipts().last { $0["nativeControllers"] != nil }?["nativeControllers"], 0)
        XCTAssertTrue(app.buttons["A"].waitForExistence(timeout: 5), "No controller: the touch gamepad must appear")
        try assertPicture(app)
    }

    func receipts() -> [[String: Double]] {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent("receipts.json")),
              let events = try? JSONSerialization.jsonObject(with: data) as? [[String: Double]] else { return [] }
        return events
    }

    func waitForReceipt(_ key: String, value: Double = 1, timeout: TimeInterval = 10) -> Bool {
        let predicate = NSPredicate { [self] _, _ in receipts().contains { $0[key] == value } }
        return XCTWaiter.wait(for: [XCTNSPredicateExpectation(predicate: predicate, object: nil)], timeout: timeout)
            == .completed
    }

    func command(_ name: String, value: String) throws {
        try Data(value.utf8).write(to: directory.appendingPathComponent(name), options: .atomic)
    }

    func record(_ name: String) {
        if application?.staticTexts["Pairing PIN"].exists == true { return }
        let shot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        shot.name = name
        shot.lifetime = .keepAlways
        add(shot)
        if let application {
            let tree = XCTAttachment(string: application.debugDescription)
            tree.name = "\(name)-accessibility"
            tree.lifetime = .keepAlways
            add(tree)
        }
    }

    func assertPicture(_ app: XCUIApplication, file: StaticString = #filePath, line: UInt = #line) throws {
        let screenshot = app.otherElements["Video from the PC"].screenshot()
        let image = try XCTUnwrap(screenshot.image.cgImage)
        JourneyPicture.assertColors(image, file: file, line: line)
        let attachment = XCTAttachment(screenshot: screenshot)
        attachment.name = "rendered-touch-gamepad"
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    func assertNeutral(_ sample: [String: Double]?, file: StaticString = #filePath, line: UInt = #line) {
        for key in ["buttons", "lt", "rt", "lx", "ly", "rx", "ry"] {
            XCTAssertEqual(sample?[key], 0, "Release must clear \(key)", file: file, line: line)
        }
    }

    func assertPCInput(since index: Int, key: String = "pcButtons", pressed: Double,
                       file: StaticString = #filePath, line: UInt = #line) {
        let expectation = XCTNSPredicateExpectation(predicate: NSPredicate { [self] _, _ in
            let samples = receipts().dropFirst(index).filter { $0["pcButtons"] != nil }
            return samples.contains { ($0[key] ?? 0) >= pressed } && samples.last?[key] == 0
        }, object: nil)
        XCTAssertEqual(XCTWaiter.wait(for: [expectation], timeout: 5), .completed,
                       "The PC must receive the press and neutral release for " + key, file: file, line: line)
    }

    func samples(since index: Int) -> [[String: Double]] {
        Array(receipts().dropFirst(index).filter { $0["buttons"] != nil })
    }

    func openMenu(_ app: XCUIApplication) {
        let menu = app.buttons["Show controls"].firstMatch
        XCTAssertTrue(menu.waitForExistence(timeout: 5))
        XCTAssertTrue(menu.isHittable)
        menu.tap()
        XCTAssertTrue(app.buttons["Disconnect"].waitForExistence(timeout: 5))
    }

    func stop(_ app: XCUIApplication) {
        openMenu(app)
        record("touch-only-disconnect")
        app.buttons["Disconnect"].tap()
        XCTAssertTrue(app.buttons["launcher-app-1"].firstMatch.waitForExistence(timeout: 10))
        XCTAssertTrue(waitForReceipt("stop"))
        XCTAssertFalse(app.otherElements["Video from the PC"].exists)
    }
}
