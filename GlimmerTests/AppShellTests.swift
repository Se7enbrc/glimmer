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

    @MainActor private func withQualityDefaults(_ body: () -> Void) {
        let keys = ["qualityPreset", "customWidth", "customHeight", "customFPS", "streamHDR",
                    StreamDisplayMode.defaultsKey, BitrateMode.defaultsKey]
        let defaults = UserDefaults.standard
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        for key in keys { defaults.removeObject(forKey: key) }
        body()
    }

    @Test @MainActor func customResolutionAndRefreshSurviveRelaunch() {
        withQualityDefaults {
            for (width, height, fps) in [(1920, 1080, 60), (1280, 720, 90), (2560, 1440, 120)] {
                let model = AppModel()
                model.qualityPreset = .custom
                model.customWidth = width
                model.customHeight = height
                model.customFPS = fps
                model.streamDisplayMode = .fullScreen
                model.streamHDR = false
                model.bitrateMode = .bandwidthSaver
                let expectedBitrate = model.effectiveBitrateKbps
                let relaunched = AppModel()
                #expect(relaunched.qualityPreset == .custom)
                #expect(relaunched.customWidth == width)
                #expect(relaunched.customHeight == height)
                #expect(relaunched.customFPS == fps)
                #expect(relaunched.streamHDR == false)
                #expect(relaunched.bitrateMode == .bandwidthSaver)
                #expect(relaunched.effectiveBitrateKbps == expectedBitrate)
                #expect(UserDefaults.standard.integer(forKey: "customWidth") == width)
                #expect(UserDefaults.standard.integer(forKey: "customHeight") == height)
                #expect(UserDefaults.standard.integer(forKey: "customFPS") == fps)
            }
        }
    }

    @Test @MainActor func fullscreenCoversEveryPanelUnlessTheUserChoseOtherwise() {
        let keys = ["streamCoversNotch", "streamUsesFullScreenSpace"]
        let defaults = UserDefaults.standard
        let saved = keys.map { ($0, defaults.object(forKey: $0)) }
        defer {
            for (key, value) in saved {
                if let value { defaults.set(value, forKey: key) } else { defaults.removeObject(forKey: key) }
            }
        }
        for key in keys { defaults.removeObject(forKey: key) }
        let fresh = AppModel()
        for hasNotch in [true, false] {
            #expect(AppModel.streamCoversNotch(displayHasNotch: hasNotch, coversNotch: fresh.streamCoversNotch,
                                               usesFullScreenSpace: fresh.streamUsesFullScreenSpace))
        }
        defaults.set(false, forKey: "streamCoversNotch")
        defaults.set(true, forKey: "streamUsesFullScreenSpace")
        let chosen = AppModel()
        #expect(!chosen.streamCoversNotch && chosen.streamUsesFullScreenSpace)
    }

    @Test @MainActor func loadingQualityDoesNotSaveUntouchedCustomValues() {
        withQualityDefaults {
            let model = AppModel()
            for key in ["qualityPreset", "customWidth", "customHeight", "customFPS"] {
                #expect(UserDefaults.standard.object(forKey: key) == nil)
            }
            let expected = model.effectiveValuesForPreset(model.qualityPreset)
            model.qualityPreset = .custom
            #expect(model.customWidth == expected.width)
            #expect(model.customHeight == expected.height)
            #expect(model.customFPS == expected.fps)
        }
    }

    @Test @MainActor func testHostRegistersDefaultsWithoutLaunchingTheApp() {
        #expect(AppDelegate.boundManager == nil)
        let registration = UserDefaults.standard.volatileDomain(forName: UserDefaults.registrationDomain)
        #expect(registration[MouseAccelerationControl.enabledDefaultsKey] as? Bool == true)
    }

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
             apps: [desktop], lastConnected: nil, serverCertPEM: nil, appVersion: nil,
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

    @Test @MainActor func quitCancelsALaunchBeforeItsRouteSettles() async throws {
        let model = AppModel()
        let route = CommandRouteWait()
        let (request, task) = try await pendingStream(model, route: route)
        let replies = CommandReplies()
        replies.requestID = request.id
        model.handleCommand(["id": UUID().uuidString, "verb": "quit", "host": tower.id])
        #expect(model.pendingCommandStream == nil)
        #expect(task.isCancelled)
        route.settle()
        await task.value
        #expect(request.task == nil)
        #expect(!model.isStreaming)
        #expect(model.nativeSession == nil)
        let deadline = ContinuousClock.now + .seconds(10)
        let reply = await replies.next(giveUp: { ContinuousClock.now >= deadline })
        #expect(reply?[CommandChannel.Key.event] == CommandChannel.Event.rejected)
        #expect(reply?[CommandChannel.Key.detail] == "Stream request cancelled.")
    }

    @Test @MainActor func quittingAnotherPCLeavesThePendingLaunchAlone() async throws {
        let model = AppModel()
        let route = CommandRouteWait()
        let (request, task) = try await pendingStream(model, route: route)
        model.handleCommand(["id": UUID().uuidString, "verb": "quit", "host": "another-pc"])
        #expect(model.pendingCommandStream === request)
        #expect(!task.isCancelled)
        model.cancelPendingCommandStream()
        route.settle()
        await task.value
    }

    @Test @MainActor func aLateRouteCannotClearTheReplacementLaunch() async throws {
        let model = AppModel()
        let firstRoute = CommandRouteWait()
        let (_, firstTask) = try await pendingStream(model, route: firstRoute)
        model.handleCommand(["id": UUID().uuidString, "verb": "quit", "host": tower.id])
        let nextRoute = CommandRouteWait()
        let (nextRequest, nextTask) = try await pendingStream(model, route: nextRoute)
        firstRoute.settle()
        await firstTask.value
        #expect(model.pendingCommandStream === nextRequest)
        #expect(!nextTask.isCancelled)
        #expect(!model.isStreaming)
        model.cancelPendingCommandStream()
        nextRoute.settle()
        await nextTask.value
    }

    @Test @MainActor func aLateRouteDoesNotDisturbAReconnectingSession() async throws {
        let model = AppModel()
        let route = CommandRouteWait()
        let (_, task) = try await pendingStream(model, route: route)
        model.handleCommand(["id": UUID().uuidString, "verb": "quit", "host": tower.id])
        let session = StreamSession()
        model.nativeSession = session
        model.isStreaming = true
        model.isReconnecting = true
        route.settle()
        await task.value
        #expect(model.nativeSession === session)
        #expect(model.isStreaming)
        #expect(model.isReconnecting)
    }

    @Test @MainActor func routePollingStopsWhenCancelledEvenIfTheRouteBecomesReady() async throws {
        var checks = 0
        let task = Task { @MainActor in
            await AppModel.poll(slices: 20, every: .seconds(10)) {
                checks += 1
                return checks > 1
            }
        }
        try #require(await AppModel.poll(slices: 2_000, every: .milliseconds(1)) { checks > 0 })
        task.cancel()
        #expect(!(await task.value))
        #expect(checks == 1)
    }

    @MainActor private func pendingStream(_ model: AppModel, route: CommandRouteWait) async throws
        -> (PendingCommandStream, Task<Void, Never>) {
        model.beginCommandStream(UUID().uuidString, app: desktop, on: tower, takeover: false,
                                 waitForRoute: { await route.wait() })
        let request = try #require(model.pendingCommandStream)
        let task = try #require(request.task)
        try #require(await AppModel.poll(slices: 2_000, every: .milliseconds(1)) { route.started })
        return (request, task)
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

@MainActor
private final class CommandRouteWait {
    private var continuation: CheckedContinuation<Void, Never>?
    var started: Bool { continuation != nil }

    func wait() async {
        await withCheckedContinuation { continuation = $0 }
    }

    func settle() {
        continuation?.resume()
        continuation = nil
    }
}
