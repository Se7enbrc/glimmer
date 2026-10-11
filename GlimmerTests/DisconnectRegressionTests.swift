// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import Testing
@testable import Glimmer

@Suite(.serialized)
struct DisconnectRegressionTests {
    @Test(arguments: [StreamError.hostUnreachable("offline"), .pairingRejected,
                      .hostCertChanged("Pair Tower again."), .hostTimedOut])
    func resumeKeepsTheUnderlyingRecovery(error: StreamError) {
        let original = AppModel.connectFailure(for: error, hostName: "Tower")
        let resumed = AppModel.connectFailure(for: ResumeFailed(underlying: error), hostName: "Tower")
        #expect(resumed.message == original.message)
        #expect(resumed.kind == (original.kind == .other ? .resumeFailed : original.kind))
    }

    @Test func anAppThatExitsBeforeResumeLaunchesFresh() async throws {
        let sunshine = FakeSunshine.scripted([
            "serverinfo": [SessionFlow.running(7)],
            "resume": [.failure(.hostRefused(message: "No running app", code: 503))],
            "launch": [SessionFlow.launched]
        ])
        let server = SessionFlow.pairedPC()
        let store = try IsolatedStore("resume-race-regression")
        defer { store.remove() }
        let session = StreamSession(backend: InputRecordingBackend(),
                                    ownershipStore: RunningAppOwnershipStore(store.defaults))
        await session.prepareLaunchFlow(server: server)
        await session.claimPC(client: FakeSunshine.clientUniqueID, appID: 7)
        let client = sunshine.client(server)
        let info = try await session.fetchAndVerifyServerInfo(network: client, pcName: "Tower")
        _ = try await session.launchWithDeadline(network: client, appID: 7, config: SessionFlow.config, info: info)
        #expect(sunshine.paths == ["serverinfo", "resume", "launch"])
        #expect(await !session.resumingHostApp)
        #expect(await session.resumeFailure == nil)
    }

    @MainActor @Test func commandDuringQuitIsRejectedWithoutASession() async throws {
        let fixture = try FakePCModel("quit-command-regression", sunshine: FakeSunshine.scripted([:]))
        defer { fixture.remove() }
        let host = try fixture.pairTower()
        let app = try #require(host.apps.first)
        var replies: [[String: String]] = []
        fixture.model.postCommandReply = { replies.append($0) }
        fixture.model.quittingHostID = host.id
        fixture.model.beginCommandStream("request", app: app, on: host, takeover: false, waitForRoute: {})
        if let task = fixture.model.pendingCommandStream?.task { await task.value }
        #expect(replies.count == 1)
        #expect(replies.first?[CommandChannel.Key.event] == CommandChannel.Event.rejected)
        #expect(replies.first?[CommandChannel.Key.detail] == "An app is quitting on Tower. Try again when it finishes.")
        #expect(fixture.model.nativeSession == nil)
        #expect(fixture.model.pendingCommandStream == nil)
        #expect(fixture.sunshine.requests.isEmpty)
    }

    @MainActor @Test func launcherExplainsWhyAQuitBlocksStreaming() throws {
        let fixture = try FakePCModel("quit-launcher-regression", sunshine: FakeSunshine.scripted([:]))
        defer { fixture.remove() }
        let host = try fixture.pairTower()
        fixture.model.quittingHostID = host.id
        fixture.model.requestStream(app: try #require(host.apps.first), on: host)
        #expect(fixture.model.nativeStreamError == "An app is quitting on Tower. Try again when it finishes.")
        #expect(fixture.model.nativeStreamErrorHostID == host.id)
        #expect(fixture.model.nativeSession == nil)
    }

    @MainActor @Test func unpairClearsOwnershipInTheInjectedStore() throws {
        let fixture = try FakePCModel("unpair-owner-regression", sunshine: FakeSunshine.scripted([:]))
        defer { fixture.remove() }
        let host = try fixture.pairTower()
        RunningAppOwnership.save(pc: host.id, appID: 1, clientID: "mac", defaults: fixture.store.defaults)
        fixture.model.unpair(host, defaults: fixture.store.defaults, supportBase: fixture.store.directory)
        #expect(RunningAppOwnership.load(pc: host.id, defaults: fixture.store.defaults) == nil)
    }

    @Test func ownershipUsesTheGlimmerNamespace() throws {
        let store = try IsolatedStore("owner-namespace-regression")
        defer { store.remove() }
        RunningAppOwnership.save(pc: "pc", appID: 7, clientID: "mac", defaults: store.defaults)
        #expect(store.defaults.data(forKey: "glimmer.runningAppOwner.pc") != nil)
        #expect(store.defaults.data(forKey: "runningAppOwner.pc") == nil)
    }

    @Test func ownershipOlderThanEightHoursIsNotTrusted() throws {
        let store = try IsolatedStore("owner-expiry-regression")
        defer { store.remove() }
        let data = try JSONSerialization.data(withJSONObject: [
            "appID": 7, "clientID": "mac",
            "recordedAt": Date().addingTimeInterval(-9 * 3600).timeIntervalSinceReferenceDate
        ])
        store.defaults.set(data, forKey: "runningAppOwner.pc")
        store.defaults.set(data, forKey: "glimmer.runningAppOwner.pc")
        #expect(RunningAppOwnership.load(pc: "pc", defaults: store.defaults) == nil)
    }

    @MainActor @Test(arguments: [false, true])
    func cliStopWithoutAMatchingStreamFails(appIsRunning: Bool) async throws {
        let fixture = try FakePCModel("stop-cli-regression", sunshine: FakeSunshine.scripted([:]))
        defer { fixture.remove() }
        try fixture.pairTower()
        let terminal = CapturedTerminal()
        let command = try GlimmerCLI.parse(["stop", "Tower"])
        let status = await CLITerminal.$write.withValue(terminal.write) {
            await GlimmerCLI.stop(command, model: fixture.model, appIsRunning: { appIsRunning }, send: { _ in
                [CommandChannel.Key.event: CommandChannel.Event.notMine]
            })
        }
        #expect(status == GlimmerCLI.Exit.failed)
        #expect(terminal.err == "Glimmer isn't streaming from Tower.\n")
        #expect(terminal.out.isEmpty)
    }

    @MainActor @Test func stopIntentWithoutAMatchingStreamReportsFailure() async throws {
        let fixture = try FakePCModel("stop-intent-regression", sunshine: FakeSunshine.scripted([:]))
        defer { fixture.remove() }
        let host = try fixture.pairTower()
        let error = await #expect(throws: PCIntentError.self) {
            try await StopStreamingIntent.stop(PCEntity(host: host), model: fixture.model)
        }
        #expect(error == .failed("Glimmer isn't streaming from Tower."))
    }

    @MainActor @Test(arguments: [false, true])
    func backToStreamOnlyAppearsInTheBackground(backgrounded: Bool) throws {
        let fixture = try FakePCModel("stream-tile-regression", sunshine: FakeSunshine.scripted([:]))
        defer { fixture.remove() }
        let host = try fixture.pairTower()
        let app = try #require(host.apps.first)
        fixture.model.lastLaunchAttempt = (app, host)
        fixture.model.isStreaming = true
        fixture.model.streamPhase = .streaming
        fixture.model.nativeStreamBackgrounded = backgrounded
        #expect(AppIconsRow.tileState(app, on: host, model: fixture.model, connectingShown: false)
                == (backgrounded ? .hiddenStream : .ready))
    }

    @Test(arguments: [-1.0, 0, 28_799, 28_800, 28_801] as [TimeInterval])
    func ownershipExpiresAtExactlyEightHours(age: TimeInterval) throws {
        let store = try IsolatedStore("owner-boundary-regression")
        defer { store.remove() }
        let recorded = Date(timeIntervalSinceReferenceDate: 800_000_000)
        RunningAppOwnership.save(pc: "pc", appID: 7, clientID: "mac", defaults: store.defaults, now: recorded)
        let owner = RunningAppOwnership.load(pc: "pc", defaults: store.defaults, now: recorded.addingTimeInterval(age))
        #expect((owner != nil) == (age >= 0 && age < 8 * 3600))
    }

    @Test(arguments: [false, true])
    func expiredOrMissingOwnershipRequiresTakeover(expired: Bool) async throws {
        let store = try IsolatedStore("owner-takeover-regression")
        defer { store.remove() }
        let server = SessionFlow.pairedPC()
        if expired {
            RunningAppOwnership.save(pc: server.uniqueId, appID: 7, clientID: FakeSunshine.clientUniqueID,
                                     defaults: store.defaults, now: Date().addingTimeInterval(-8 * 3600))
        }
        let sunshine = FakeSunshine.scripted(["serverinfo": [SessionFlow.running(7)]])
        let session = StreamSession(backend: InputRecordingBackend(),
                                    ownershipStore: RunningAppOwnershipStore(store.defaults))
        await session.prepareLaunchFlow(server: server)
        let client = sunshine.client(server)
        let info = try await session.fetchAndVerifyServerInfo(network: client, pcName: "Tower")
        await #expect(throws: TakeoverRequired.self) {
            _ = try await session.launchWithDeadline(network: client, appID: 7, config: SessionFlow.config, info: info)
        }
        #expect(sunshine.paths == ["serverinfo"])
    }

    @MainActor @Test func quitStartingDuringTheRouteWaitRejectsTheCommand() async throws {
        let fixture = try FakePCModel("quit-route-regression", sunshine: FakeSunshine.scripted([:]))
        defer { fixture.remove() }
        let host = try fixture.pairTower()
        let app = try #require(host.apps.first)
        var replies: [[String: String]] = []
        fixture.model.postCommandReply = { replies.append($0) }
        let entered = SafetyTestGate()
        let route = SafetyTestGate()
        fixture.model.beginCommandStream("request", app: app, on: host, takeover: false, waitForRoute: {
            await entered.open()
            await route.wait()
        })
        let task = try #require(fixture.model.pendingCommandStream?.task)
        await entered.wait()
        fixture.model.quittingHostID = host.id
        await route.open()
        await task.value
        #expect(replies.count == 1)
        #expect(replies.first?[CommandChannel.Key.event] == CommandChannel.Event.rejected)
        #expect(fixture.model.nativeSession == nil)
        #expect(fixture.model.pendingCommandStream == nil)
        #expect(fixture.sunshine.requests.isEmpty)
    }
}
