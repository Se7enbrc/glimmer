// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import XCTest

@MainActor
final class IPadNavigationTests: XCTestCase {
    func testLauncherSettingsAndAddressEntry() throws {
        let app = XCUIApplication()
        app.launchEnvironment["GLIMMER_UI_TESTING"] = "empty"
        app.launch()
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            let settings = app.buttons["Settings"]
            XCTAssertTrue(settings.waitForExistence(timeout: 10))
            XCTAssertTrue(settings.isHittable)
            recordScreen(app, name: "native-launcher-\(orientation.rawValue)")
            if UIDevice.current.userInterfaceIdiom == .pad {
                settings.hover()
                recordScreen(app, name: "native-settings-hover-\(orientation.rawValue)")
            }
            settings.tap()
            XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
            for page in ["General", "Quality", "Input", "Diagnostics"] {
                app.buttons[page].tap()
                XCTAssertTrue(app.navigationBars[page].waitForExistence(timeout: 5))
                recordScreen(app, name: "native-\(page)-\(orientation.rawValue)")
                app.navigationBars[page].buttons.element(boundBy: 0).tap()
            }
            app.buttons["PCs"].tap()
            let add = app.buttons["Add PC by address…"]
            XCTAssertTrue(add.waitForExistence(timeout: 5))
            XCTAssertTrue(add.isHittable)
            recordScreen(app, name: "native-PCs-\(orientation.rawValue)")
            add.tap()
            let field = app.textFields["IP address or hostname"]
            XCTAssertTrue(field.waitForExistence(timeout: 5))
            XCTAssertTrue(field.isHittable)
            XCTAssertFalse(app.buttons["Connect"].isEnabled)
            field.typeText("pc.invalid")
            XCTAssertTrue(app.buttons["Connect"].isEnabled)
            recordScreen(app, name: "native-add-PC-\(orientation.rawValue)")
            app.buttons["Cancel"].tap()
        }
        app.terminate()
    }

    func testSingleAppUsesOneGridColumn() {
        let app = XCUIApplication()
        app.launchEnvironment["GLIMMER_UI_TESTING"] = "one"
        app.launch()
        defer { app.terminate() }
        XCUIDevice.shared.orientation = .landscapeLeft
        let desktop = app.buttons["Desktop"]
        XCTAssertTrue(desktop.waitForExistence(timeout: 10))
        recordScreen(app, name: "single-app-grid")
        XCTAssertLessThan(desktop.frame.width, app.windows.firstMatch.frame.width / 2)
        XCTAssertGreaterThanOrEqual(desktop.frame.height, 44)
    }

    func testWindowAndPCPickerKeepControlsReachable() {
        for largeText in [false, true] { inspectWindow(largeText: largeText) }
    }

    private func inspectWindow(largeText: Bool) {
        let app = XCUIApplication()
        app.launchEnvironment["GLIMMER_UI_TESTING"] = "many"
        if largeText {
            app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        }
        app.launch()
        defer { app.terminate() }
        let suffix = largeText ? "ax5" : "default"
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
        recordScreen(app, name: "native-window-full-\(suffix)")
        app.buttons.matching(identifier: "Living room gaming PC 1").firstMatch.tap()
        let lastPC = app.buttons["Living room gaming PC 12"]
        for _ in 0..<12 {
            if lastPC.isHittable { break }
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(lastPC.waitForExistence(timeout: 5))
        XCTAssertTrue(lastPC.isHittable)
        recordScreen(app, name: "native-pc-picker-\(suffix)")
        app.typeKey(".", modifierFlags: .command)
        XCTAssertTrue(lastPC.waitForNonExistence(timeout: 5))
        if min(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height) >= 700 {
            let fullSize = app.windows.firstMatch.frame.size
            for fraction in [0.35, 0.65, 0.98] {
                let window = app.windows.firstMatch
                let handle = window.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.99))
                let target = app.coordinate(withNormalizedOffset: .zero).withOffset(
                    CGVector(dx: fullSize.width * fraction,
                             dy: fullSize.height * fraction))
                handle.press(forDuration: 0.3, thenDragTo: target)
                XCTAssertTrue(app.buttons["Settings"].isHittable)
                recordScreen(app, name: "native-window-request-\(Int(fraction * 100))-\(suffix)")
            }
        }
    }

    func testDefaultTextKeepsPCNamesVisible() {
        let app = XCUIApplication()
        app.launchEnvironment["GLIMMER_UI_TESTING"] = "many"
        app.launch()
        defer { app.terminate() }
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
        app.buttons["Settings"].tap()
        app.buttons["PCs"].tap()
        let name = app.collectionViews.staticTexts["Living room gaming PC 1"]
        XCTAssertTrue(name.waitForExistence(timeout: 5))
        XCTAssertGreaterThan(name.frame.width, 100)
        XCTAssertLessThan(name.frame.height, 100)
        XCTAssertTrue(name.isHittable)
        recordScreen(app, name: "default-text-pc-names")
    }

    func testLargeTextKeepsForgetBelowPCName() {
        let app = XCUIApplication()
        app.launchEnvironment["GLIMMER_UI_TESTING"] = "many"
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        defer { app.terminate() }
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons.matching(identifier: "Desktop").firstMatch.waitForExistence(timeout: 10))
        recordScreen(app, name: "native-large-text-gallery")
        app.buttons["Settings"].tap()
        app.buttons["PCs"].tap()
        let name = app.collectionViews.staticTexts["Living room gaming PC 1"]
        let forget = app.buttons["Forget Living room gaming PC 1"]
        XCTAssertTrue(forget.waitForExistence(timeout: 5))
        recordScreen(app, name: "large-text-pc-actions")
        XCTAssertGreaterThanOrEqual(forget.frame.minY, name.frame.maxY)
        XCTAssertTrue(forget.isHittable)
    }

    private func recordScreen(_ app: XCUIApplication, name: String) {
        let screenshot = XCTAttachment(screenshot: XCUIScreen.main.screenshot())
        screenshot.name = name
        screenshot.lifetime = .keepAlways
        add(screenshot)
        let hierarchy = XCTAttachment(string: app.debugDescription)
        hierarchy.name = "\(name)-accessibility"
        hierarchy.lifetime = .keepAlways
        add(hierarchy)
    }
}
