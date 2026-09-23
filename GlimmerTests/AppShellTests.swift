//
//  AppShellTests.swift
//
//  The app around the stream: when Glimmer keeps a Dock icon and Cmd-Tab
//  entry.
//

import AppKit
import Testing
@testable import Glimmer

struct AppShellTests {

    @Test func dockIconStaysWhileThereIsSomethingToComeBackTo() {
        let policy = AppDelegate.activationPolicy
        #expect(policy(["main"], false) == .regular)
        #expect(policy(["com_apple_SwiftUI_Settings_window"], false) == .regular)
        // A stream started from the menu bar, launcher closed.
        #expect(policy([], true) == .regular)
        #expect(policy([], false) == .accessory)
    }

    @Test func menuBarPanelsAndAlertsDontEarnADockIcon() {
        let policy = AppDelegate.activationPolicy
        #expect(policy(["com_apple_SwiftUI_MenuBarExtraPanel", "NSAlert"], false) == .accessory)
    }
}
