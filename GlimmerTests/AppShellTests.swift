//
//  AppShellTests.swift
//
//  The app around the stream: when Glimmer keeps a Dock icon and Cmd-Tab
//  entry, and how it answers `glimmer stream` and `glimmer quit`.
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

    private let desktop = LibraryApp(id: 7, name: "Desktop", hdr: false, hidden: false)

    private var tower: Glimmer.Host {
        Host(id: "UUID-1", name: "Tower", customName: nil, localAddress: "192.0.2.10", manualAddress: nil,
             apps: [desktop], lastConnected: nil, serverCertPEM: nil, appVersion: nil, gfeVersion: nil,
             macAddress: nil)
    }

    private func decide(
        _ info: [String: String], streamingFrom: String? = nil, handled: inout Set<String>
    ) -> CommandChannel.Decision? {
        CommandChannel.decide(info, handled: &handled, hosts: [tower], streamingFrom: streamingFrom)
    }

    @Test func aRepeatedRequestStartsOneStream() {
        var handled: Set<String> = []
        let request = ["id": "r1", "verb": "stream", "host": "UUID-1", "app": "7", "takeover": "1"]
        #expect(decide(request, handled: &handled) == .stream(desktop, on: tower, takeover: true))
        #expect(decide(request, handled: &handled) == nil)
        var other = request
        other["id"] = "r2"
        other["takeover"] = "0"
        #expect(decide(other, handled: &handled) == .stream(desktop, on: tower, takeover: false))
    }

    @Test func streamRequestsTheAppCantServeAreRejectedWithTheReason() {
        var handled: Set<String> = []
        let unknown = CommandChannel.Decision.rejected("Glimmer doesn't know that PC or app.")
        #expect(decide(["id": "a", "verb": "stream", "host": "UUID-9", "app": "7"], handled: &handled) == unknown)
        #expect(decide(["id": "b", "verb": "stream", "host": "UUID-1", "app": "8"], handled: &handled) == unknown)
        #expect(decide(["id": "c", "verb": "stream", "host": "UUID-1"], handled: &handled) == unknown)
        let busy = decide(["id": "d", "verb": "stream", "host": "UUID-1", "app": "7"],
                          streamingFrom: "UUID-2", handled: &handled)
        #expect(busy == .rejected(CommandChannel.alreadyStreaming))
    }

    @Test func checkTellsTheTerminalWhetherAStreamWouldBeTaken() {
        var handled: Set<String> = []
        #expect(decide(["id": "a", "verb": "check", "host": "UUID-1"], handled: &handled) == .ready)
        // Streaming, or a request still waiting on its route: asking about a takeover would be moot.
        #expect(decide(["id": "b", "verb": "check", "host": "UUID-1"], streamingFrom: "UUID-1", handled: &handled)
            == .rejected(CommandChannel.alreadyStreaming))
    }

    @Test @MainActor func routeWaitStopsAtTheFirstSettledCheckOrAfterTheBudget() async {
        var checks = 0
        #expect(await AppModel.poll(slices: 20, every: .milliseconds(1)) { checks += 1; return checks == 3 })
        #expect(checks == 3)
        checks = 0
        #expect(!(await AppModel.poll(slices: 4, every: .milliseconds(1)) { checks += 1; return false }))
        #expect(checks == 5)
    }

    @Test func routeSettlesOnceTheAskHasEverythingALauncherClickWouldHave() {
        #expect(AppModel.routeSettled(.wired, phyMbps: nil))
        #expect(AppModel.routeSettled(.tunnel, phyMbps: nil))
        // Wi-Fi before its first PHY read would ask the full boost with no radio gate.
        #expect(!AppModel.routeSettled(.wifi, phyMbps: nil))
        #expect(AppModel.routeSettled(.wifi, phyMbps: 1100))
        #expect(!AppModel.routeSettled(.unknown, phyMbps: nil))
    }

    @Test func quitStopsOnlyAStreamFromThatPC() {
        var handled: Set<String> = []
        #expect(decide(["id": "a", "verb": "quit", "host": "UUID-1"], handled: &handled) == .notMine)
        #expect(decide(["id": "b", "verb": "quit", "host": "UUID-1"], streamingFrom: "UUID-2", handled: &handled)
            == .notMine)
        #expect(decide(["id": "c", "verb": "quit", "host": "UUID-1"], streamingFrom: "UUID-1", handled: &handled)
            == .stop)
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
