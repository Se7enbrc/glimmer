// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AppIntents
import Foundation
import Observation
import Testing
@testable import Glimmer
@testable import GlimmerEngine

@Suite(.timeLimit(.minutes(1)))
@MainActor
struct IOSCommandTests {
    @Test(arguments: [false, true])
    func launchAndStopUseTheLauncherAndDisconnectSetting(leaveRunning: Bool) async throws {
        let fixture = LauncherFixture()
        let model = fixture.model()
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.leaveGamesRunning = leaveRunning
        try await model.streamFromCommand(pc: fixture.pcID, app: " game ")
        let session = try #require(model.session)
        #expect(session.launch.appID == fixture.app.id)
        #expect(session.launch.hostDisposition == (leaveRunning ? .disconnectOnly : .cancelOwnedHostSession))
        try await model.streamFromCommand(pc: fixture.pcID, app: "Game")
        #expect(model.session === session)
        #expect(await model.stopFromCommand(matching: "another PC") == .pcMismatch)
        #expect(model.session === session)
        #expect(await model.stopFromCommand() == .stopped)
        #expect(model.session == nil)
        #expect(await model.stopFromCommand() == .noActiveStream)
        #expect(fixture.pairs == 0)
    }

    @Test(arguments: [false, true])
    func coldLaunchWaitsForForegroundAndStopCancelsIt(cancel: Bool) async throws {
        let fixture = LauncherFixture()
        let model = fixture.model()
        let launch = Task { try await model.streamFromCommand(pc: fixture.pcID, app: "Game") }
        for await pending in Observations({ model.pendingCommand }) where pending { break }
        #expect(model.session == nil)
        if cancel {
            #expect(await model.stopFromCommand(matching: "another PC") == .pcMismatch)
            #expect(await model.stopFromCommand(matching: fixture.pcID) == .stopped)
            _ = await model.stopFromCommand()
            await #expect(throws: CancellationError.self) { try await launch.value }
        } else {
            model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
            try await launch.value
            #expect(model.session?.launch.appID == fixture.app.id)
            _ = await model.stopFromCommand()
        }
    }

    @Test func backgroundQuitUsesThePinnedPreparationAndSharedQuit() async throws {
        let fixture = LauncherFixture()
        fixture.runningAppID = fixture.app.id
        let model = fixture.model()
        try await model.quitFromCommand(pc: fixture.pcID, confirmation: false)
        #expect(fixture.quitIDs == [fixture.app.id])
        #expect(fixture.pairs == 0 && model.session == nil && !model.active)
    }

    @Test func unknownPCAndAppCannotLaunch() async {
        let fixture = LauncherFixture()
        let model = fixture.model()
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        await #expect(throws: PCIntentError.notPaired) {
            try await model.streamFromCommand(pc: "missing", app: nil)
        }
        await #expect(throws: PCIntentError.noApp("missing", pc: "Test PC")) {
            try await model.streamFromCommand(pc: fixture.pcID, app: "missing")
        }
        #expect(model.session == nil && fixture.pairs == 0)
    }

    @Test func stopCancelsAPendingLaunchBeforePreparationReturns() async throws {
        let fixture = LauncherFixture()
        let gate = StreamTestGate()
        fixture.prepareGate = gate
        let model = fixture.model()
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        let launch = Task { try await model.streamFromCommand(pc: fixture.pcID, app: "Game") }
        await gate.waitUntilEntered()
        #expect(await model.stopFromCommand(matching: "another PC") == .pcMismatch)
        #expect(await model.stopFromCommand(matching: fixture.pcID) == .stopped)
        _ = await model.stopFromCommand()
        await gate.release()
        do {
            try await launch.value
            Issue.record("Stopped launch must be cancelled")
        } catch is CancellationError {} catch {
            Issue.record("Expected cancellation, got \(error)")
        }
        #expect(model.session == nil)
    }

    @Test func runningGameReplacementUsesTheExistingConfirmation() async throws {
        let fixture = LauncherFixture()
        fixture.runningAppID = fixture.hidden.id
        let model = fixture.model()
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        try await model.streamFromCommand(pc: fixture.pcID, app: fixture.app.name)
        let action = try #require(model.pendingGameAction)
        #expect(model.session == nil && action.running.id == fixture.hidden.id)
        model.confirmGameAction(action)
        #expect(model.session?.launch.approvedOccupant == fixture.hidden.id)
        #expect(model.session?.launch.appID == fixture.app.id)
        _ = await model.stopFromCommand()
    }

    @Test(arguments: [false, true])
    func activeReplacementWaitsForDisposalAndHonorsStop(cancel: Bool) async throws {
        let fixture = LauncherFixture()
        let playback = PlaybackFixture()
        let disposal = StreamTestGate()
        playback.stop = { await disposal.wait() }
        var sessions = 0
        fixture.makeSession = { launch in sessions += 1; return playback.model(launch: launch) }
        let model = fixture.model()
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        try await model.streamFromCommand(pc: fixture.pcID, app: fixture.app.name)
        let old = try #require(model.session)
        old.start(surface: StreamSurface())
        old.receive(playback.update(.firstFrame))
        try await model.streamFromCommand(pc: fixture.pcID, app: fixture.hidden.name)
        let action = try #require(model.pendingGameAction)
        #expect(sessions == 1 && !old.inputFocused)
        model.confirmGameAction(action)
        let replacement = try #require(model.commandTask)
        await disposal.waitUntilEntered()
        #expect(sessions == 1)
        if cancel {
            let stopping = Task { await model.stopFromCommand(matching: fixture.pcID) }
            while model.commandTask != nil { await Task.yield() }
            await disposal.release()
            #expect(await stopping.value == .stopped)
        } else { await disposal.release() }
        await replacement.value
        #expect(sessions == (cancel ? 1 : 2))
        if cancel { #expect(model.session == nil) } else {
            #expect(model.session?.launch.appID == fixture.hidden.id)
            #expect(model.session?.launch.approvedOccupant == fixture.app.id)
            _ = await model.stopFromCommand()
        }
    }

    @Test func linksKeepTheMacGrammarAndQuitConfirmation() async throws {
        let url = try #require(URL(string: "glimmer://stream?pc=Den%20PC&app=Desktop"))
        let command = try #require(GlimmerCommandURL.parse(url))
        #expect(command.action == .stream && command.pc == "Den PC" && command.app == "Desktop")
        for text in ["glimmer://stream", "glimmer://stop?app=Desktop", "glimmer://stop?pc=A&pc=B",
                     "glimmer://stream?pc=A&force=true", "glimmer://stop/path", "glimmer://stop#fragment"] {
            #expect(GlimmerCommandURL.parse(try #require(URL(string: text))) == nil)
        }
        let fixture = LauncherFixture()
        fixture.runningAppID = fixture.app.id
        let model = fixture.model()
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        try await model.quitFromCommand(pc: fixture.pcID, confirmation: true)
        #expect(model.pendingGameAction?.target == nil)
        #expect(model.pendingGameAction?.running.id == fixture.app.id && fixture.quitIDs.isEmpty)
        model.pendingGameAction = nil
        try await model.quitFromCommand(pc: fixture.pcID, confirmation: false)
        #expect(fixture.quitIDs == [fixture.app.id])
    }

    @Test(arguments: [false, true])
    func externalStopCannotEndTheSessionWithoutConfirmation(leaveRunning: Bool) async throws {
        let fixture = LauncherFixture()
        let model = fixture.model()
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.leaveGamesRunning = leaveRunning
        try await model.streamFromCommand(pc: fixture.pcID, app: fixture.app.name)
        let original = try #require(model.session)
        await model.handleCommandURL(try #require(URL(string: "glimmer://stop")))?.value
        #expect(model.session === original)
        #expect(!original.phase.isEnded)
        let cancelled = try #require(model.pendingURLCommand)
        model.pendingURLCommand = nil
        #expect(model.confirmURLCommand(cancelled) == nil)
        #expect(model.session === original)
        await model.handleCommandURL(try #require(URL(string: "glimmer://stop")))?.value
        let approved = try #require(model.pendingURLCommand)
        await model.confirmURLCommand(approved)?.value
        #expect(model.session == nil)
        #expect(model.confirmURLCommand(approved) == nil)
    }

    @Test func externalLaunchCannotStartWithoutConfirmation() async throws {
        let fixture = LauncherFixture()
        let model = fixture.model()
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        let url = try #require(URL(string: "glimmer://stream?pc=\(fixture.pcID)&app=Game"))
        await model.handleCommandURL(url)?.value
        #expect(model.session == nil)
        let request = try #require(model.pendingURLCommand)
        await model.confirmURLCommand(request)?.value
        #expect(model.session?.launch.appID == fixture.app.id)
        _ = await model.stopFromCommand()
    }

    @Test func aStaleExternalStopCannotEndAReplacementSession() async throws {
        let fixture = LauncherFixture()
        let model = fixture.model()
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        try await model.streamFromCommand(pc: fixture.pcID, app: fixture.app.name)
        await model.handleCommandURL(try #require(URL(string: "glimmer://stop")))?.value
        let request = try #require(model.pendingURLCommand)
        _ = await model.stopFromCommand()
        try await model.streamFromCommand(pc: fixture.pcID, app: fixture.hidden.name)
        let replacement = try #require(model.session)
        await model.confirmURLCommand(request)?.value
        #expect(model.session === replacement)
        _ = await model.stopFromCommand()
    }

    @Test func applicationRegistersLinksAndExtractsTheSharedShortcuts() throws {
        let schemes = try #require(Bundle.main.object(forInfoDictionaryKey: "CFBundleURLTypes") as? [[String: Any]])
        #expect(schemes.contains { ($0["CFBundleURLSchemes"] as? [String])?.contains("glimmer") == true })
        let metadata = try #require(Bundle.main.url(forResource: "extract", withExtension: "actionsdata",
                                                   subdirectory: "Metadata.appintents"))
        let document = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: metadata)) as? [String: Any])
        let actions = try #require(document["actions"] as? [String: Any])
        #expect(Set(actions.keys) == ["StreamIntent", "StopStreamingIntent", "QuitAppOnPCIntent"])
        let stream = try #require(actions["StreamIntent"] as? [String: Any])
        let parameters = try #require(stream["parameters"] as? [[String: Any]])
        #expect(parameters.compactMap { $0["name"] as? String } == ["pc", "app"])
        #expect(stream["openAppWhenRun"] as? Bool == true)
        let entities = try #require(document["entities"] as? [String: Any])
        #expect(entities["PCEntity"] != nil)
    }

    @Test func sharedIntentNamesAndPCParametersRemainAvailable() {
        #expect(String(localized: StreamIntent.title) == "Stream from PC")
        #expect(String(localized: StopStreamingIntent.title) == "Stop Streaming")
        #expect(String(localized: QuitAppOnPCIntent.title) == "Quit App on PC")
        let entity = PCEntity(id: "pc", name: "Den PC")
        let intent = StreamIntent()
        intent.pc = entity
        intent.app = "Desktop"
        #expect(intent.pc == entity && intent.app == "Desktop")
    }
}
