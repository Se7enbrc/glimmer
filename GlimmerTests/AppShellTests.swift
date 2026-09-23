//
//  AppShellTests.swift
//
//  The app around the stream: when Glimmer keeps a Dock icon and Cmd-Tab
//  entry, and what it reports back to `glimmer stream`.
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

    @Test @MainActor func connectTimingsAreWholeMillisecondsOrAbsent() {
        let timing = ConnectTimingTelemetry.shared
        timing.resetForNewSession()
        defer { timing.resetForNewSession() }
        #expect(AppModel.connectTimings().isEmpty)
        timing.recordLaunchLeg(serverinfoMs: 41.6, launchMs: 380.2)
        let values = AppModel.connectTimings()
        #expect(values["serverinfo_ms"] == "42")
        #expect(values["launch_ms"] == "380")
        #expect(values["cancel_ms"] == nil)
    }
}
