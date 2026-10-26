// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import XCTest

@MainActor
final class IPadNavigationTests: XCTestCase {
    func testRunningTileScreenshots() {
        let app = XCUIApplication()
        app.launchEnvironment["GLIMMER_UI_TESTING"] = "running"
        app.launch()
        defer { app.terminate() }
        XCUIDevice.shared.orientation = .portrait
        let tile = app.buttons["launcher-app-1"]
        XCTAssertTrue(tile.waitForExistence(timeout: 10))
        recordScreen(app, name: "running-launcher")
        tile.press(forDuration: 1)
        recordScreen(app, name: "running-context-menu")
        let point = app.buttons["Quit Desktop…"]
            .coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).screenPoint
        app.coordinate(withNormalizedOffset: CGVector(dx: 0.95, dy: 0.95)).tap()
        let quit = app.coordinate(withNormalizedOffset: .zero).withOffset(CGVector(dx: point.x, dy: point.y))
        tile.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).press(forDuration: 1, thenDragTo: quit)
        XCTAssertTrue(app.alerts["Quit Desktop on Living room gaming PC 1?"].waitForExistence(timeout: 5))
        recordScreen(app, name: "running-quit-alert")
        app.alerts.buttons["Cancel"].tap()
        let other = app.buttons["launcher-app-3"]
        XCTAssertTrue(other.waitForExistence(timeout: 5))
        other.tap()
        XCTAssertTrue(app.alerts["Quit Desktop and start SuperTuxKart?"].waitForExistence(timeout: 5))
        recordScreen(app, name: "running-switch-alert")
        app.alerts.buttons["Cancel"].tap()
    }

    func testStreamStartsInPortraitAndResizedWindows() throws {
        let app = XCUIApplication()
        app.launchEnvironment["GLIMMER_UI_TESTING"] = "stream"
        if let mode = ProcessInfo.processInfo.environment["GLIMMER_NATIVE_WINDOW_MODE"] {
            inspectSystemStream(mode, app: app)
            return
        }
        app.launch()
        defer { app.terminate() }
        for orientation in [UIDeviceOrientation.portrait, .landscapeLeft] {
            XCUIDevice.shared.orientation = orientation
            XCTAssertTrue(app.buttons["Desktop"].waitForExistence(timeout: 10))
            app.buttons["Desktop"].tap()
            // Without a controller the stream starts in touch play; its menu button opens the controls.
            let menu = app.buttons["Show controls"].firstMatch
            XCTAssertTrue(menu.waitForExistence(timeout: 10))
            XCTAssertTrue(menu.isHittable)
            menu.tap()
            XCTAssertTrue(app.buttons["Close menu"].waitForExistence(timeout: 10))
            XCTAssertTrue(app.buttons["Disconnect"].isHittable)
            recordScreen(app, name: "whole-window-native-stream-\(orientation.rawValue)")
            app.buttons["Disconnect"].tap()
            XCTAssertTrue(app.buttons["Desktop"].waitForExistence(timeout: 10))
        }
        if UIDevice.current.userInterfaceIdiom == .pad {
            let window = app.windows.firstMatch
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.99))
                .press(forDuration: 0.3, thenDragTo: window.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.35, dy: 0.35)))
        }
        app.buttons["Desktop"].tap()
        // A window too small for touch controls opens on the stream menu instead of its menu button.
        let way = app.buttons.matching(NSPredicate(format: "label IN %@", ["Show controls", "Disconnect"])).firstMatch
        XCTAssertTrue(way.waitForExistence(timeout: 10))
        XCTAssertTrue(way.isHittable)
        recordScreen(app, name: "whole-window-native-resize-request")
    }

    private func inspectSystemStream(_ mode: String, app: XCUIApplication) {
        let settings = XCUIApplication(bundleIdentifier: "com.apple.Preferences")
        settings.activate()
        let multitasking = settings.buttons["Multitasking & Gestures"]
        if multitasking.waitForExistence(timeout: 5) { multitasking.tap() }
        let choice = "com.apple.settings.multitaskingAndGestures."
            + (mode == "stage" ? "stageManager" : "windowedApps")
        let option = settings.descendants(matching: .any).matching(identifier: choice).firstMatch
        XCTAssertTrue(option.waitForExistence(timeout: 5))
        option.tap()
        app.launch()
        defer { app.terminate() }
        XCUIDevice.shared.orientation = .landscapeLeft
        XCTAssertTrue(app.buttons["Desktop"].waitForExistence(timeout: 10))
        recordScreen(app, name: "whole-window-\(mode)-initial")
        let window = app.windows.firstMatch
        window.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.99))
            .press(forDuration: 0.3, thenDragTo: window.coordinate(
                withNormalizedOffset: CGVector(dx: 0.35, dy: 0.35)))
        if mode != "stage" {
            let system = XCUIApplication(bundleIdentifier: "com.apple.springboard")
            let controls = system.buttons["window-controls:io.ugfugl.Glimmer.iOS"]
            XCTAssertTrue(controls.waitForExistence(timeout: 5))
            controls.tap()
            system.buttons["Zoom-button"].press(forDuration: 1)
            let item = system.descendants(matching: .any)
                .matching(identifier: mode == "slide" ? "Enter Slide Over" : "Left and Right").firstMatch
            let exitSlide = system.descendants(matching: .any).matching(identifier: "Exit Slide Over").firstMatch
            if mode == "slide", exitSlide.exists {
                recordScreen(system, name: "whole-window-slide-already-active")
                app.windows.firstMatch.coordinate(withNormalizedOffset: CGVector(dx: 0.9, dy: 0.85)).tap()
            } else {
                XCTAssertTrue(item.waitForExistence(timeout: 5))
                item.tap()
            }
        }
        recordScreen(app, name: "whole-window-\(mode)-launcher")
        app.buttons["Desktop"].tap()
        XCTAssertTrue(app.buttons["Close menu"].waitForExistence(timeout: 10))
        XCTAssertTrue(app.buttons["Disconnect"].isHittable)
        XCTAssertLessThan(app.windows.firstMatch.frame.width, app.windows.firstMatch.frame.height)
        recordScreen(app, name: "whole-window-\(mode)-stream")
        app.buttons["Disconnect"].tap()
        XCTAssertTrue(app.buttons["Desktop"].waitForExistence(timeout: 10))
    }

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
            #if GLIMMER_DIAGNOSTICS
            let pages = ["General", "Quality", "Input", "Diagnostics"]
            #else
            let pages = ["General", "Quality", "Input"]
            #endif
            for page in pages {
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
        app.connectHardwareKeyboard()
        recordScreen(app, name: "native-window-full-\(suffix)")
        app.buttons.matching(identifier: "Living room gaming PC 1").firstMatch.tap()
        let lastPC = app.buttons["pc-picker-fixture-11"]
        for _ in 0..<12 {
            if lastPC.isHittable { break }
            app.collectionViews.firstMatch.swipeUp()
        }
        XCTAssertTrue(lastPC.waitForExistence(timeout: 5))
        XCTAssertEqual(lastPC.label, "Living room gaming PC 12")
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

    func testSettingsKeyboardCommands() {
        let app = XCUIApplication()
        app.launchEnvironment["GLIMMER_UI_TESTING"] = "empty"
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
        app.connectHardwareKeyboard()
        app.typeKey(",", modifierFlags: .command)
        XCTAssertTrue(app.navigationBars["Settings"].waitForExistence(timeout: 5))
        recordScreen(app, name: "settings-keyboard-open")
        app.typeKey(".", modifierFlags: .command)
        XCTAssertTrue(app.navigationBars["Settings"].waitForNonExistence(timeout: 5))
        recordScreen(app, name: "settings-keyboard-close")
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

    func testWindowLargestTextKeepsSettingsRowsReadable() {
        let app = XCUIApplication()
        app.launchEnvironment["GLIMMER_UI_TESTING"] = "many"
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        defer { app.terminate() }
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
        if app.windows.firstMatch.frame.width > 450 {
            let window = app.windows.firstMatch
            window.coordinate(withNormalizedOffset: CGVector(dx: 0.99, dy: 0.99))
                .press(forDuration: 0.3, thenDragTo: window.coordinate(
                    withNormalizedOffset: CGVector(dx: 0.35, dy: 0.35)))
        }
        app.scrollViews.firstMatch.swipeUp()
        let desktop = app.buttons.matching(identifier: "Desktop").firstMatch
        XCTAssertTrue(desktop.waitForExistence(timeout: 5))
        recordScreen(app, name: "largest-text-short-app-name")
        app.buttons["Settings"].tap()
        let general = app.buttons["General"]
        XCTAssertTrue(general.waitForExistence(timeout: 5))
        recordScreen(app, name: "largest-text-short-settings-name")
        XCTAssertLessThan(general.frame.height, 110)
    }

    func testLargestTextShowsFullQualityChoices() {
        let app = XCUIApplication()
        app.launchEnvironment["GLIMMER_UI_TESTING"] = "empty"
        app.launchArguments = ["-UIPreferredContentSizeCategoryName", "UICTContentSizeCategoryAccessibilityXXXL"]
        app.launch()
        defer { app.terminate() }
        XCUIDevice.shared.orientation = .portrait
        XCTAssertTrue(app.buttons["Settings"].waitForExistence(timeout: 10))
        app.buttons["Settings"].tap()
        app.buttons["Quality"].tap()
        recordScreen(app, name: "largest-text-quality-choices")
        for label in ["Native · 120 fps", "1080p · 60 fps", "1080p · 120 fps"] {
            let choice = app.descendants(matching: .any).matching(identifier: label).firstMatch
            for _ in 0..<3 where !choice.isHittable { app.swipeUp() }
            XCTAssertTrue(choice.waitForExistence(timeout: 5))
            XCTAssertTrue(choice.isHittable)
            XCTAssertGreaterThan(choice.frame.height, 44)
        }
        recordScreen(app, name: "largest-text-quality-scrolled")
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
