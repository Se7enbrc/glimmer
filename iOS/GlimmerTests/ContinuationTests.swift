// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GameController
import GlimmerEngine
import Testing
import UIKit
@testable import Glimmer

@Suite(.serialized)
@MainActor
struct ContinuationTests {
    @Test func controllerMenuPressUsesTheFocusedActionAndReleasesItsHandler() async throws {
        let controller = GCController.withExtendedGamepad()
        let button = try #require(controller.extendedGamepad?.buttonMenu)
        let menu = LauncherMenuController(controllers: { [controller] })
        let events = AsyncStream<Void>.makeStream()
        var calls = 0
        menu.openMenu = { calls += 1; events.continuation.yield(()) }
        menu.start()
        let handler = try #require(button.pressedChangedHandler)
        handler(button, 0, false)
        handler(button, 1, true)
        var iterator = events.stream.makeAsyncIterator()
        await iterator.next()
        #expect(calls == 1)
        menu.stop()
        #expect(button.pressedChangedHandler == nil)
        events.continuation.finish()
    }

    @Test func launcherCannotReinstallMenuHandlersWhileStreaming() throws {
        let controller = GCController.withExtendedGamepad()
        let button = try #require(controller.extendedGamepad?.buttonMenu)
        let menu = LauncherMenuController(controllers: { [controller] })
        menu.update(active: true, streaming: false)
        #expect(button.pressedChangedHandler != nil)
        menu.update(active: true, streaming: true)
        #expect(button.pressedChangedHandler == nil)
        // Foreground and hotplug refreshes must obey the same ownership gate.
        menu.update(active: false, streaming: true)
        menu.update(active: true, streaming: true)
        #expect(button.pressedChangedHandler == nil)
        menu.update(active: true, streaming: false)
        #expect(button.pressedChangedHandler != nil)
        menu.stop()
    }

    @Test func runningTileResumesDirectlyAndQuitMenuKeepsItsNamedApproval() async throws {
        let fixture = LauncherFixture()
        fixture.runningAppID = fixture.app.id
        let model = fixture.model()
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.select(fixture.saved)
        await model.waitUntilOperationFinishes()
        model.requestQuit()
        let quit = try #require(model.pendingGameAction)
        #expect(quit.running.id == fixture.app.id && quit.target == nil)
        #expect(fixture.quitIDs.isEmpty)
        model.pendingGameAction = nil
        model.activateTile(fixture.app)
        let stream = try #require(model.stream)
        #expect(stream.launch.appID == fixture.app.id && stream.launch.continuing)
        #expect(model.pendingGameAction == nil && fixture.quitIDs.isEmpty)
        model.activateTile(fixture.app)
        #expect(model.stream === stream)
        model.streamClosed()
        await model.waitUntilStreamClosed()
    }

    @Test func anotherTileAsksOnceAndDoesNotQuitUntilApproved() async throws {
        let fixture = LauncherFixture()
        fixture.runningAppID = fixture.hidden.id
        let model = fixture.model()
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.select(fixture.saved)
        await model.waitUntilOperationFinishes()
        model.activateTile(fixture.app)
        await model.waitUntilOperationFinishes()
        let approval = try #require(model.pendingGameAction)
        #expect(approval.running.id == fixture.hidden.id && approval.target?.id == fixture.app.id)
        #expect(model.stream == nil && fixture.quitIDs.isEmpty)
        model.confirmGameAction(approval)
        #expect(model.stream?.launch.approvedOccupant == fixture.hidden.id)
        #expect(model.pendingGameAction == nil)
        model.streamClosed()
        await model.waitUntilStreamClosed()
    }

    @Test(arguments: [false, true])
    func runningHiddenGameRemainsActionableAndUsesDisconnectSetting(leaveRunning: Bool) async throws {
        let fixture = LauncherFixture()
        fixture.runningAppID = fixture.hidden.id
        let model = fixture.model()
        model.leaveGamesRunning = leaveRunning
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.select(fixture.saved)
        await model.waitUntilOperationFinishes()
        #expect(model.apps.map(\.id) == [fixture.app.id])
        #expect(model.runningApp?.name == fixture.hidden.name)
        #expect(model.runningAppOutsideGallery?.id == fixture.hidden.id)
        model.continueGame()
        let stream = try #require(model.stream)
        #expect(stream.launch.appID == fixture.hidden.id)
        #expect(stream.launch.continuing)
        #expect(stream.launch.hostDisposition == (leaveRunning ? .disconnectOnly : .cancelOwnedHostSession))
        model.continueGame()
        #expect(model.stream === stream)
        model.streamClosed()
        await model.waitUntilStreamClosed()
    }

    @Test func switchingGamesRequiresOneNamedApprovalAndCancelDoesNothing() async throws {
        let fixture = LauncherFixture()
        fixture.runningAppID = fixture.hidden.id
        let model = fixture.model()
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.select(fixture.saved)
        await model.waitUntilOperationFinishes()
        model.launch(fixture.app)
        await model.waitUntilOperationFinishes()
        #expect(model.stream == nil)
        let action = try #require(model.pendingGameAction)
        #expect(action.running.id == fixture.hidden.id && action.target?.id == fixture.app.id)
        model.pendingGameAction = nil
        #expect(fixture.quitIDs.isEmpty && model.stream == nil)
        model.launch(fixture.app)
        await model.waitUntilOperationFinishes()
        model.confirmGameAction(try #require(model.pendingGameAction))
        #expect(model.stream?.launch.approvedOccupant == fixture.hidden.id)
        #expect(model.stream?.launch.appID == fixture.app.id)
        model.streamClosed()
        await model.waitUntilStreamClosed()
    }

    @Test func duplicateStandaloneQuitUsesOneCommandAndRefreshes() async throws {
        let fixture = LauncherFixture()
        fixture.runningAppID = fixture.app.id
        let model = fixture.model()
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.select(fixture.saved)
        await model.waitUntilOperationFinishes()
        model.requestQuit()
        let action = try #require(model.pendingGameAction)
        model.confirmGameAction(action)
        model.confirmGameAction(action)
        await model.waitUntilOperationFinishes()
        await model.waitUntilOperationFinishes()
        #expect(fixture.quitIDs == [fixture.app.id])
        #expect(model.runningApp == nil)
    }

    @Test(arguments: [false, true])
    func graceExpiryUsesTheSessionSettingAndNeverRestoresInput(leaveRunning: Bool) async {
        let fixture = PlaybackFixture()
        let original = testLaunch()
        let launch = StreamLaunch(network: original.network, pcID: original.pcID, pcName: original.pcName,
                                  appID: original.appID, appName: original.appName, leaveGamesRunning: leaveRunning)
        let gate = StreamTestGate()
        var now: TimeInterval = 0
        fixture.backgroundCalls = .init(begin: { _ in .init(rawValue: 42) }, end: { _ in },
                                         now: { now }, sleep: { await gate.wait() })
        let model = fixture.model(launch: launch)
        model.start(surface: StreamSurface())
        model.receive(fixture.update(.firstFrame))
        model.resumeInput()
        model.availabilityChanged(active: false, background: true, protectedDataAvailable: true)
        now = 16
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        await gate.release()
        await model.waitUntilStopped()
        #expect(fixture.completedStops == 1 && !model.inputFocused)
        #expect(launch.hostDisposition == (leaveRunning ? .disconnectOnly : .cancelOwnedHostSession))
    }

    @Test func endedContinuationSurvivesBackgroundRefreshWithoutLaunchingAgain() async throws {
        let fixture = LauncherFixture()
        fixture.runningAppID = fixture.app.id
        let model = fixture.model()
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.select(fixture.saved)
        await model.waitUntilOperationFinishes()
        model.continueGame()
        let session = try #require(model.stream)
        session.continuationEnded?()
        fixture.runningAppID = 0
        model.availabilityChanged(active: false, background: true, protectedDataAvailable: true)
        model.streamClosed()
        await model.waitUntilStreamClosed()
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.selectInitialPCIfNeeded()
        await model.waitUntilOperationFinishes()
        #expect(model.endedGame?.id == fixture.app.id)
        #expect(model.stream == nil && model.streamReturn == nil)
    }

    @Test func terminatedSizeTrialIsRejectedBeforeAnyRecovery() {
        let fixture = PlaybackFixture()
        fixture.format = StreamFormat(width: 2622, height: 1206, fps: 120)
        let original = testLaunch()
        let previous = ContinuationFormat(width: 1920, height: 1080, fps: 60, hdr: false)
        let launch = StreamLaunch(network: original.network, pcID: original.pcID, pcName: original.pcName,
            appID: original.appID, appName: original.appName, leaveGamesRunning: true,
            continuing: true, previousFormat: previous, useScreenSize: true)
        let model = fixture.model(launch: launch)
        var rejected: StreamFormat?
        model.startupFailed = { rejected = $0 }
        model.start(surface: StreamSurface())
        model.receive(fixture.update(.firstFrame))
        #expect(model.pictureNeedsReview)
        model.receive(fixture.update(.connectionTerminated(errorCode: -1)))
        #expect(rejected == fixture.format && !model.pictureNeedsReview)
        model.receive(fixture.update(.stopped))
    }

    @Test func continuationKeepsKnownSizeAndUnknownFormatDoesNotRequestResize() {
        let original = testLaunch()
        let previous = ContinuationFormat(width: 1920, height: 1080, fps: 60, hdr: false)
        let native = StreamFormat(width: 2622, height: 1206, fps: 120)
        let known = StreamLaunch(network: original.network, pcID: "pc", pcName: "PC", appID: 1, appName: "Game",
                                 continuing: true, previousFormat: previous)
        #expect(StreamFormat.continuing(known, native: native, maximumFPS: 120)
            == StreamFormat(width: 1920, height: 1080, fps: 60))
        let unknown = StreamLaunch(network: original.network, pcID: "pc", pcName: "PC", appID: 1, appName: "Game",
                                   continuing: true)
        #expect(!StreamFormat.continuing(unknown, native: native, maximumFPS: 120).changeResolution)
        #expect(StreamFormat.continuing(original, native: native, maximumFPS: 120) == native)
    }
}
