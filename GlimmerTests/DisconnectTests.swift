// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import Testing
@testable import Glimmer

@Suite(.serialized)
struct DisconnectTests {
    @Test(arguments: [DisconnectReason.userStopped, .hostError, .consumerDropped, .connectFailed])
    func everyStopLeavesTheGameRunning(cause: DisconnectReason) async throws {
        let sunshine = FakeSunshine.scripted(["launch": [SessionFlow.launched], "cancel": [SessionFlow.cancelled]])
        let server = SessionFlow.pairedPC()
        let store = try IsolatedStore(UUID().uuidString)
        defer { store.remove() }
        let session = StreamSession(backend: InputRecordingBackend(), makeNetwork: { sunshine.client($0) },
                                    ownershipStore: RunningAppOwnershipStore(store.defaults))
        await session.prepareLaunchFlow(server: server)
        _ = try await session.launchAndRecordOwnership(client: FakeSunshine.clientUniqueID, appID: 7) {
            try await sunshine.client(server).launch(appID: 7, config: SessionFlow.config)
        }
        await session.stop(cause: cause)
        await session.stop()
        #expect(sunshine.paths == ["launch"])
        #expect(await !session.isStreaming)
        #expect(await !session.stopInProgress)
        #expect(RunningAppOwnership.load(pc: server.uniqueId, defaults: store.defaults)?.appID == 7)
    }

    @Test func lateLaunchSuccessAfterStopIsRetainedWithoutCancel() async throws {
        let sunshine = FakeSunshine.scripted(["cancel": [SessionFlow.cancelled]])
        let server = SessionFlow.pairedPC()
        let store = try IsolatedStore(UUID().uuidString)
        defer { store.remove() }
        let session = StreamSession(backend: InputRecordingBackend(), makeNetwork: { sunshine.client($0) },
                                    ownershipStore: RunningAppOwnershipStore(store.defaults))
        await session.prepareLaunchFlow(server: server)
        let entered = SafetyTestGate()
        let reply = SafetyTestGate()
        let launch = Task {
            try await session.launchAndRecordOwnership(client: FakeSunshine.clientUniqueID, appID: 7) {
                await entered.open()
                await reply.wait()
                return LaunchResponse(sessionURL: "", gcmKey: Data(), gcmKeyId: Data())
            }
        }
        await entered.wait()
        await session.stop()
        #expect(await session.pendingLaunch != nil)
        await reply.open()
        _ = try await launch.value
        #expect(sunshine.requests.isEmpty)
        #expect(RunningAppOwnership.load(pc: server.uniqueId, defaults: store.defaults)?.appID == 7)
    }

    @Test(arguments: [false, true])
    func savedOwnershipSurvivesANewSessionButNeverAuthorizesAnotherClient(foreign: Bool) async throws {
        let server = SessionFlow.pairedPC()
        let store = try IsolatedStore(UUID().uuidString)
        defer { store.remove() }
        RunningAppOwnership.save(pc: server.uniqueId, appID: 7,
                                 clientID: foreign ? "another-client" : FakeSunshine.clientUniqueID,
                                 defaults: store.defaults)
        let sunshine = FakeSunshine.scripted(["serverinfo": [SessionFlow.running(7)], "resume": [SessionFlow.launched]])
        let client = sunshine.client(server)
        let session = StreamSession(backend: InputRecordingBackend(),
                                    ownershipStore: RunningAppOwnershipStore(store.defaults))
        await session.prepareLaunchFlow(server: server)
        let info = try await session.fetchAndVerifyServerInfo(network: client, pcName: "Tower")
        var config = SessionFlow.config
        config.width = 2560
        config.height = 1440
        config.fps = 120
        config.videoFormats = [.hevcMain10]
        do {
            _ = try await session.launchWithDeadline(network: client, appID: 7, config: config, info: info)
            #expect(!foreign)
            #expect(sunshine.paths == ["serverinfo", "resume"])
            #expect(sunshine.requests.last?.query["mode"] == "2560x1440x120")
            #expect(sunshine.requests.last?.query["hdrMode"] == "1")
        } catch is TakeoverRequired {
            #expect(foreign)
            #expect(sunshine.paths == ["serverinfo"])
        }
    }

    @Test func ourDifferentRunningAppStillNeedsConfirmation() async throws {
        let server = SessionFlow.pairedPC()
        let store = try IsolatedStore(UUID().uuidString)
        defer { store.remove() }
        RunningAppOwnership.save(pc: server.uniqueId, appID: 9, clientID: FakeSunshine.clientUniqueID,
                                 defaults: store.defaults)
        let sunshine = FakeSunshine.scripted(["serverinfo": [SessionFlow.running(9)]])
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

    @Test func pollingIdleOrAnotherAppClearsOwnership() throws {
        let store = try IsolatedStore("running-ownership")
        defer { store.remove() }
        RunningAppOwnership.save(pc: "pc", appID: 7, clientID: "mac", defaults: store.defaults)
        RunningAppOwnership.reconcile(pc: "pc", appID: 7, defaults: store.defaults)
        #expect(RunningAppOwnership.load(pc: "pc", defaults: store.defaults)?.clientID == "mac")
        RunningAppOwnership.reconcile(pc: "pc", appID: 9, defaults: store.defaults)
        #expect(RunningAppOwnership.load(pc: "pc", defaults: store.defaults) == nil)
        RunningAppOwnership.save(pc: "pc", appID: 7, clientID: "mac", defaults: store.defaults)
        RunningAppOwnership.reconcile(pc: "pc", appID: 0, defaults: store.defaults)
        #expect(RunningAppOwnership.load(pc: "pc", defaults: store.defaults) == nil)
    }

    @MainActor @Test func explicitQuitDisconnectsThenCancelsAndClearsOwnership() async throws {
        let sunshine = FakeSunshine.scripted(["cancel": [SessionFlow.cancelled]])
        let fixture = try FakePCModel("disconnect-quit", sunshine: sunshine)
        defer { fixture.remove() }
        let host = try fixture.pairTower()
        let session = StreamSession(backend: InputRecordingBackend(), makeNetwork: { sunshine.client($0) },
                                    ownershipStore: RunningAppOwnershipStore(fixture.store.defaults))
        await session.prepareLaunchFlow(server: fixture.model.nativeServerInfo(for: host))
        fixture.model.nativeSession = session
        fixture.model.isStreaming = true
        fixture.model.lastLaunchAttempt = (try #require(host.apps.first), host)
        RunningAppOwnership.save(pc: host.id, appID: 1, clientID: FakeSunshine.clientUniqueID,
                                 defaults: fixture.store.defaults)
        try await fixture.model.quitRunningApp(on: host)
        #expect(await !session.isStreaming)
        #expect(sunshine.paths == ["cancel"])
        #expect(RunningAppOwnership.load(pc: host.id, defaults: fixture.store.defaults) == nil)
    }

    @MainActor @Test(arguments: [false, true])
    func quitIntentRequiresConfirmationBeforeCancel(confirmed: Bool) async throws {
        let sunshine = FakeSunshine.scripted(["cancel": [SessionFlow.cancelled]])
        let fixture = try FakePCModel("disconnect-intent", sunshine: sunshine)
        defer { fixture.remove() }
        let host = try fixture.pairTower()
        fixture.model.hostLiveStatus = HostLiveStatus(hostID: host.id, state: .streamingApp(name: "Desktop"),
                                                      rttMs: 3, sunshineVersion: nil, capturedAt: Date())
        do {
            try await QuitAppOnPCIntent.quit(PCEntity(host: host), model: fixture.model) { app, pc in
                #expect(app.name == "Desktop" && pc.id == host.id)
                #expect(sunshine.requests.isEmpty)
                if !confirmed { throw CancellationError() }
            }
            #expect(confirmed)
        } catch is CancellationError { #expect(!confirmed) }
        #expect(sunshine.paths == (confirmed ? ["cancel"] : []))
    }

    @MainActor @Test func stopIntentDisconnectsWithoutCancel() async throws {
        let sunshine = FakeSunshine.scripted(["cancel": [SessionFlow.cancelled]])
        let fixture = try FakePCModel("disconnect-stop-intent", sunshine: sunshine)
        defer { fixture.remove() }
        let host = try fixture.pairTower()
        let session = StreamSession(backend: InputRecordingBackend(), makeNetwork: { sunshine.client($0) },
                                    ownershipStore: RunningAppOwnershipStore(fixture.store.defaults))
        await session.prepareLaunchFlow(server: fixture.model.nativeServerInfo(for: host))
        await session.claimPC(client: FakeSunshine.clientUniqueID, appID: 1)
        fixture.model.nativeSession = session
        fixture.model.isStreaming = true
        fixture.model.lastLaunchAttempt = (try #require(host.apps.first), host)
        try await StopStreamingIntent.stop(PCEntity(host: host), model: fixture.model)
        #expect(await !session.isStreaming)
        #expect(sunshine.requests.isEmpty)
    }

    @MainActor @Test func cliStopAndQuitAreDistinctAndQuitNeedsConfirmation() throws {
        #expect(try GlimmerCLI.parse(["stop", "Tower"]).verb == .stop)
        #expect(try GlimmerCLI.parse(["quit", "Tower", "--force"]).flags.contains("--force"))
        let host = Glimmer.Host(id: "pc", name: "Tower", customName: nil,
                               localAddress: "192.0.2.10", manualAddress: nil,
                        apps: [], lastConnected: nil, serverCertPEM: nil, appVersion: nil, macAddress: nil)
        var handled: Set<String> = []
        #expect(CommandChannel.decide(["id": "stop", "host": "pc", "verb": "stop"],
                                      handled: &handled, hosts: [host], streamingFrom: "pc") == .stop)
        #expect(CommandChannel.decide(["id": "quit", "host": "pc", "verb": "quit"],
                                      handled: &handled, hosts: [host], streamingFrom: "pc") == .quit(host))
        let terminal = CapturedTerminal()
        CLITerminal.$write.withValue(terminal.write) {
            #expect(!GlimmerCLI.confirmQuit(app: "Hades", pc: "Tower", interactive: false))
            #expect(!GlimmerCLI.confirmQuit(app: "Hades", pc: "Tower", interactive: true, answer: { "n" }))
            #expect(GlimmerCLI.confirmQuit(app: "Hades", pc: "Tower", interactive: true, answer: { "yes" }))
        }
        #expect(terminal.err.contains("Quit Hades on Tower?"))
        #expect(terminal.err.contains("Unsaved progress may be lost."))
    }

    @MainActor @Test(arguments: [false, true])
    func cliConfirmedQuitUsesTheAppOrTheSharedCancelPath(appIsRunning: Bool) async throws {
        let sunshine = FakeSunshine.scripted(["cancel": [SessionFlow.cancelled]])
        let fixture = try FakePCModel("disconnect-cli-quit", sunshine: sunshine)
        defer { fixture.remove() }
        let host = try fixture.pairTower()
        let terminal = CapturedTerminal()
        let result = await CLITerminal.$write.withValue(terminal.write) {
            await GlimmerCLI.quitConfirmed(running: "Desktop", on: host, model: fixture.model,
                                          appIsRunning: { appIsRunning }, send: { request in
                #expect(request[CommandChannel.Key.verb] == "quit")
                #expect(request[CommandChannel.Key.host] == host.id)
                try? await fixture.model.quitRunningApp(on: host)
                return [CommandChannel.Key.event: CommandChannel.Event.stopped]
            })
        }
        #expect(result == GlimmerCLI.Exit.ok)
        #expect(sunshine.paths == ["cancel"])
        #expect(terminal.out == "Quit Desktop on Tower.\n")
    }

    @MainActor @Test func anUnansweredQuitNeverRacesTheAppWithCancel() async throws {
        let sunshine = FakeSunshine.scripted([:])
        let fixture = try FakePCModel("disconnect-cli-no-reply", sunshine: sunshine)
        defer { fixture.remove() }
        let host = try fixture.pairTower()
        let terminal = CapturedTerminal()
        let result = await CLITerminal.$write.withValue(terminal.write) {
            await GlimmerCLI.quitConfirmed(running: "Desktop", on: host, model: fixture.model,
                                          appIsRunning: { true }, send: { _ in nil })
        }
        #expect(result == GlimmerCLI.Exit.failed)
        #expect(sunshine.requests.isEmpty)
    }

    @MainActor @Test func explicitQuitWaitsForAPendingLaunch() async throws {
        let sunshine = FakeSunshine.scripted(["cancel": [SessionFlow.cancelled]])
        let fixture = try FakePCModel("disconnect-quit-pending", sunshine: sunshine)
        defer { fixture.remove() }
        let host = try fixture.pairTower()
        let session = StreamSession(backend: InputRecordingBackend(), makeNetwork: { sunshine.client($0) },
                                    ownershipStore: RunningAppOwnershipStore(fixture.store.defaults))
        await session.prepareLaunchFlow(server: fixture.model.nativeServerInfo(for: host))
        fixture.model.nativeSession = session
        fixture.model.isStreaming = true
        fixture.model.lastLaunchAttempt = (try #require(host.apps.first), host)
        let entered = SafetyTestGate()
        let reply = SafetyTestGate()
        let launch = Task {
            try await session.launchAndRecordOwnership(client: FakeSunshine.clientUniqueID, appID: 1) {
                await entered.open()
                await reply.wait()
                return LaunchResponse(sessionURL: "", gcmKey: Data(), gcmKeyId: Data())
            }
        }
        await entered.wait()
        let quit = Task { try await fixture.model.quitRunningApp(on: host) }
        await fixture.waitUntil { fixture.model.quittingHostID == host.id }
        #expect(sunshine.requests.isEmpty)
        await reply.open()
        _ = try await launch.value
        try await quit.value
        #expect(await !session.isStreaming)
        #expect(sunshine.paths == ["cancel"])
        #expect(RunningAppOwnership.load(pc: host.id, defaults: fixture.store.defaults) == nil)
    }

    @MainActor @Test func resumeLabelsRequireAFreshMatchingRunningApp() async throws {
        let fixture = try FakePCModel("resume-label", sunshine: FakeSunshine.scripted([:]))
        defer { fixture.remove() }
        let host = try fixture.pairTower()
        let app = try #require(host.apps.first)
        fixture.model.hostLiveStatus = HostLiveStatus(hostID: host.id, state: .streamingApp(name: app.name),
                                                      rttMs: 3, sunshineVersion: nil, capturedAt: Date())
        #expect(fixture.model.streamActionTitle(app, on: host) == "Stream Desktop")
        RunningAppOwnership.save(pc: host.id, appID: app.id, clientID: FakeSunshine.clientUniqueID,
                                 defaults: fixture.store.defaults)
        #expect(fixture.model.streamActionTitle(app, on: host) == "Resume Desktop")
        fixture.model.hostLiveStatus?.capturedAt = .distantPast
        #expect(!fixture.model.canResume(app, on: host))
        fixture.model.hostLiveStatus?.capturedAt = Date()
        fixture.model.hostLiveStatus?.state = .idle
        #expect(fixture.model.runningApp(on: host) == nil)
    }

    @Test func confirmedRelaunchOfOurAppCancelsThenLaunches() async throws {
        let server = SessionFlow.pairedPC()
        let store = try IsolatedStore(UUID().uuidString)
        defer { store.remove() }
        RunningAppOwnership.save(pc: server.uniqueId, appID: 7, clientID: FakeSunshine.clientUniqueID,
                                 defaults: store.defaults)
        let sunshine = FakeSunshine.scripted(["serverinfo": [SessionFlow.running(7), SessionFlow.idle],
                                               "cancel": [SessionFlow.cancelled], "launch": [SessionFlow.launched]])
        let session = StreamSession(backend: InputRecordingBackend(),
                                    ownershipStore: RunningAppOwnershipStore(store.defaults))
        await session.prepareLaunchFlow(server: server)
        await session.authorizeTakeover(true)
        let client = sunshine.client(server)
        let info = try await session.fetchAndVerifyServerInfo(network: client, pcName: "Tower")
        _ = try await session.launchWithDeadline(network: client, appID: 7, config: SessionFlow.config, info: info)
        #expect(sunshine.paths == ["serverinfo", "cancel", "serverinfo", "launch"])
    }

    @MainActor @Test func unpairForgetsTheRunningAppOwner() async throws {
        let fixture = try FakePCModel("disconnect-unpair", sunshine: FakeSunshine.scripted([:]))
        defer { fixture.remove() }
        let host = try fixture.pairTower()
        RunningAppOwnership.save(pc: host.id, appID: 1, clientID: FakeSunshine.clientUniqueID,
                                 defaults: fixture.store.defaults)
        fixture.model.unpair(host, defaults: fixture.store.defaults, supportBase: fixture.store.directory)
        #expect(RunningAppOwnership.load(pc: host.id, defaults: fixture.store.defaults) == nil)
    }

    @MainActor @Test func stopDuringSessionSetupLatchesBeforeTheActorExists() async {
        let model = AppModel()
        model.isStreaming = true
        #expect(await !model.stopOwnStream(source: "the command line"))
        #expect(model.menuStopInProgress)
        #expect(model.nativeSession == nil)
    }

    @Test func explicitQuitWaitsForALaunchAfterItsSessionWasDiscarded() async throws {
        let store = try IsolatedStore("discarded-launch")
        defer { store.remove() }
        let mutations = HostLaunchMutations()
        let entered = SafetyTestGate()
        let reply = SafetyTestGate()
        let cancelled = SafetyTestCounter()
        let quitEntered = SafetyTestGate()
        let launch = try await mutations.launch(pc: "discarded", client: "mac", appID: 7,
                                                store: RunningAppOwnershipStore(store.defaults)) {
            await entered.open()
            await reply.wait()
            return LaunchResponse(sessionURL: "", gcmKey: Data(), gcmKeyId: Data())
        }
        await entered.wait()
        let quit = Task {
            await quitEntered.open()
            try await mutations.cancel(pc: "discarded") { await cancelled.increment() }
        }
        await quitEntered.wait()
        #expect(await cancelled.value == 0)
        await reply.open()
        _ = try await launch.value
        try await quit.value
        #expect(await cancelled.value == 1)
        RunningAppOwnership.clear(pc: "discarded", defaults: store.defaults)
    }

    @MainActor @Test(arguments: [false, true])
    func quitIntentProbeFailuresKeepTheSharedRecoveryCopy(trustChanged: Bool) async throws {
        let sunshine = FakeSunshine.scripted([
            "serverinfo": [.failure(.hostUnreachable("TLS cert mismatch"))]
        ])
        let fixture = try FakePCModel("quit-intent-probe", sunshine: sunshine,
                                      rtt: trustChanged ? .reachable(rttMs: 3) : .unreachable)
        defer { fixture.remove() }
        let host = try fixture.pairTower()
        let error = await #expect(throws: PCIntentError.self) {
            try await QuitAppOnPCIntent.quit(PCEntity(host: host), model: fixture.model) { _, _ in
                Issue.record("A failed probe must not ask to quit an unidentified app")
            }
        }
        let message = trustChanged ? NetworkClient.notPaired(host.displayName).description
            : AppModel.unreachableMessage(host.displayName)
        #expect(error == .failed(message))
        #expect(!sunshine.paths.contains("cancel"))
    }
}
