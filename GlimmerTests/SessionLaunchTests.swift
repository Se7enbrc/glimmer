// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import Testing
@testable import Glimmer

// Sessions construct real audio engines; keep setup from contending across these tests.
@Suite(.serialized)
struct SessionLaunchTests {
    @Test func launchOwnershipSurvivesAnUncertainResponse() {
        #expect(!StreamSession.retainsLaunchOwnership(after: StreamError.hostRefused(message: "Busy", code: 503)))
        #expect(StreamSession.retainsLaunchOwnership(after: CancellationError()))
        #expect(StreamSession.retainsLaunchOwnership(after: StreamError.hostTimedOut))
        #expect(StreamSession.retainsLaunchOwnership(after: StreamError.hostUnreachable("Connection closed")))
        #expect(StreamSession.retainsLaunchOwnership(after: StreamError.launchFailed("Malformed response")))
    }

    @Test func stopCancelsInitialServerInfoBeforeItsTimeout() async {
        let session = StreamSession()
        await session.prepareLaunchTestSession()
        let entered = SafetyTestGate()
        let request = Task {
            try await session.fetchInitialServerInfo {
                await entered.open()
                try await Task.sleep(for: .seconds(30))
                return ServerInfo(address: "192.0.2.1", uniqueId: "pc", serverName: "Den PC")
            }
        }
        defer { request.cancel() }
        await entered.wait()
        #expect(await session.initialServerInfoTask != nil)
        let stopping = Task { await session.stop() }
        // Request cancellation must not wait for unrelated UI and backend teardown.
        let cancelled = await TerminationGate.runBounded(seconds: 2) { _ = await request.result }
        #expect(cancelled)
        request.cancel()
        await #expect(throws: CancellationError.self) { try await request.value }
        #expect(await session.initialServerInfoTask == nil)
        await stopping.value
        #expect(await !session.stopInProgress)
    }

    /// A pipeline's events go to the session it started for, whichever is current when they fire,
    /// so a late callback from a timed-out pipeline can't land in the next session.
    @Test func eventsGoToTheSessionTheirPipelineStartedFor() async {
        let session = StreamSession()
        let bridge = StreamBridgeContext(session: session, videoDecoder: await VideoDecoder(),
                                         audioDecoder: AudioDecoder(), inputForwarder: await InputForwarder())
        let (stream, continuation) = AsyncStream<StreamEvent>.makeStream()
        bridge.eventContinuation = continuation
        NativeConnectionEvents(bridge: bridge).stageStarting("name resolution")
        continuation.finish()
        var received = 0
        for await _ in stream { received += 1 }
        #expect(received == 1)
    }

    /// The disconnected control client still closes after a failed reconnect.
    @Test func stopCanCloseClientAfterAFailedReconnectAttempt() async {
        let session = StreamSession()
        await session.loseNetworkAfterReconnect(to: ServerInfo(address: "192.0.2.1", uniqueId: "pc", serverName: "Den PC"))
        let cleanup = await session.cleanupNetwork
        #expect(await cleanup?.server.uniqueId == "pc")
    }

    @Test func stopFinishesWhileLaunchRemainsPending() async {
        let session = StreamSession()
        await session.prepareLaunchTestSession()
        await session.publishLaunchTestBridge()
        let entered = SafetyTestGate()
        let response = SafetyTestGate()
        let launch = Task {
            try await session.launchAndRecordOwnership(client: "client", appID: 1) {
                await entered.open()
                await response.wait()
                return Self.response
            }
        }
        await entered.wait()
        #expect(await session.bridge != nil)
        #expect(await session.pendingLaunch != nil)
        #expect(session.terminationStopBoundSeconds == 2)
        let finished = await TerminationGate.runBounded(seconds: 5) { await session.stop() }
        #expect(finished)
        #expect(await session.pendingLaunch != nil)
        #expect(await !session.stopInProgress)
        #expect(await !session.ownsHostSession)
        await response.open()
        _ = await launch.result
    }

    @Test(arguments: [StreamError.hostTimedOut, StreamError.hostUnreachable("Connection closed")])
    func busyRecoveryKeepsOwnershipAfterTransportFailure(error: StreamError) async throws {
        let session = StreamSession()
        await session.prepareLaunchTestSession()
        var info = ServerInfo(address: "", uniqueId: "", serverName: "")
        info.currentGameID = 1
        let network = NetworkClient(server: info)
        await network.prepareLaunchTestClient()
        do {
            _ = try await session.launchAndRecordOwnership(client: "client", appID: 1) { throw error }
            Issue.record("Launch should have failed")
        } catch {
            #expect(StreamSession.retainsLaunchOwnership(after: error))
        }
        try await session.authorizeOccupancy(info, network: network, deadline: .distantFuture)
        #expect(await session.ownsHostSession)
        #expect(await session.hostSessionClientID == "client")
    }

    @Test func differentAppAfterUncertainLaunchRequiresTakeover() async throws {
        let session = StreamSession()
        await session.prepareLaunchTestSession()
        var info = ServerInfo(address: "", uniqueId: "", serverName: "")
        info.currentGameID = 2
        let network = NetworkClient(server: info)
        await network.prepareLaunchTestClient()
        _ = try? await session.launchAndRecordOwnership(client: "client", appID: 1) {
            throw StreamError.hostTimedOut
        }
        do {
            try await session.authorizeOccupancy(info, network: network, deadline: .distantFuture)
            Issue.record("A different app must require takeover")
        } catch let takeover as TakeoverRequired {
            #expect(takeover.appID == 2)
        }
        #expect(await !session.ownsHostSession)
    }

    @Test(arguments: [false, true])
    func olderLaunchCannotClearNewerLaunch(refused: Bool) async throws {
        let session = StreamSession()
        let firstEntered = SafetyTestGate()
        let firstResponse = SafetyTestGate()
        let secondEntered = SafetyTestGate()
        let secondResponse = SafetyTestGate()
        let first = Task {
            try await session.launchAndRecordOwnership(client: "first", appID: 1) {
                await firstEntered.open()
                await firstResponse.wait()
                if refused { throw StreamError.hostRefused(message: "Busy", code: 503) }
                return Self.response
            }
        }
        await firstEntered.wait()
        let second = Task {
            try await session.launchAndRecordOwnership(client: "second", appID: 1) {
                await secondEntered.open()
                await secondResponse.wait()
                return Self.response
            }
        }
        await secondEntered.wait()
        let pending = await session.pendingLaunch
        await firstResponse.open()
        _ = await first.result
        #expect(pending != nil)
        #expect(await session.pendingLaunch == pending)
        #expect(await session.ownsHostSession)
        #expect(await session.hostSessionClientID == "second")
        #expect(await session.hostSessionAppID == 1)
        await secondResponse.open()
        _ = try await second.value
        #expect(await session.pendingLaunch == nil)
    }

    @Test func newLaunchWaitsForAnAlreadySendingExplicitQuit() async throws {
        let mutations = HostLaunchMutations()
        let epoch = try await mutations.beginLaunch(for: "pc")
        let cancelEntered = SafetyTestGate()
        let cancelResponse = SafetyTestGate()
        let launchEntered = SafetyTestGate()
        let launchStarted = SafetyTestGate()
        let cleanup = Task {
            try? await mutations.cancel(pc: "pc") {
                await cancelEntered.open()
                await cancelResponse.wait()
            }
        }
        await cancelEntered.wait()
        let launch = Task {
            await launchEntered.open()
            let current = try await mutations.beginLaunch(for: "pc")
            await launchStarted.open()
            return current
        }
        await launchEntered.wait()
        let overtookCancel = await TerminationGate.runBounded(seconds: 0.05) { await launchStarted.wait() }
        #expect(!overtookCancel)
        // An unrelated PC does not wait on this one's HTTPS request.
        #expect(try await mutations.beginLaunch(for: "other-pc") == 1)
        await cancelResponse.open()
        await cleanup.value
        #expect(try await launch.value == epoch + 2)
    }

    @Test func cancellingAQueuedLaunchDoesNotClaimThePc() async throws {
        let mutations = HostLaunchMutations()
        let epoch = try await mutations.beginLaunch(for: "pc")
        let entered = SafetyTestGate()
        let response = SafetyTestGate()
        let cleanup = Task {
            try? await mutations.cancel(pc: "pc") {
                await entered.open()
                await response.wait()
            }
        }
        await entered.wait()
        let launch = Task { try await mutations.beginLaunch(for: "pc") }
        launch.cancel()
        await response.open()
        await cleanup.value
        await #expect(throws: CancellationError.self) { try await launch.value }
        #expect(try await mutations.beginLaunch(for: "pc") == epoch + 2)
    }

    private static var response: LaunchResponse {
        LaunchResponse(sessionURL: "", gcmKey: Data(), gcmKeyId: Data())
    }
}

private extension StreamSession {
    func prepareLaunchTestSession() { isStreaming = true }

    func useServer(_ server: ServerInfo) { reconnectServer = server }

    func loseNetworkAfterReconnect(to server: ServerInfo) {
        reconnectServer = server
        network = nil
    }

    func publishLaunchTestBridge() async {
        let decoder = await VideoDecoder()
        let forwarder = await InputForwarder()
        bridge = StreamBridgeContext(session: self, videoDecoder: decoder,
                                     audioDecoder: audioDecoder, inputForwarder: forwarder)
    }
}

private extension NetworkClient {
    func prepareLaunchTestClient() { clientUniqueID = "client" }
}
