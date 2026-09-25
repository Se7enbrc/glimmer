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

    @Test(arguments: [false, true])
    func settledLaunchDeterminesWhetherToCancel(refused: Bool) async {
        let session = StreamSession()
        let entered = SafetyTestGate()
        let response = SafetyTestGate()
        let cancelled = SafetyTestCounter()
        let launch = Task {
            try await session.launchAndRecordOwnership(client: "client", appID: 1) {
                await entered.open()
                await response.wait()
                if refused { throw StreamError.hostRefused(message: "Busy", code: 503) }
                return Self.response
            }
        }
        await entered.wait()
        let cleanup = Task {
            await session.settlePendingLaunch { await cancelled.increment() }
        }
        await response.open()
        await cleanup.value
        _ = await launch.result
        #expect(await cancelled.value == (refused ? 0 : 1))
        #expect(await session.ownsHostSession == !refused)
        #expect(await session.hostSessionClientID == (refused ? nil : "client"))
    }

    @Test func cancelledConnectReturnsBeforeReplyAndLateSuccessIsCancelledAgain() async {
        let session = StreamSession()
        let entered = SafetyTestGate()
        let response = SafetyTestGate()
        let cancelled = SafetyTestCounter()
        let twice = SafetyTestGate()
        let attempt = Task {
            try await StreamAttempt.run(until: Date().addingTimeInterval(30)) {
                try await session.launchAndRecordOwnership(client: "client", appID: 1) {
                    await entered.open()
                    await response.wait()
                    try Task.checkCancellation()
                    return Self.response
                }
            }
        }
        await entered.wait()
        attempt.cancel()
        let cancelledPromptly = await TerminationGate.runBounded(seconds: 5) {
            do {
                _ = try await attempt.value
                Issue.record("Cancelled connect returned a launch response")
            } catch {
                #expect(error is CancellationError)
            }
            await session.settlePendingLaunch {
                await cancelled.increment()
                if await cancelled.value == 2 { await twice.open() }
            }
        }
        #expect(cancelledPromptly)
        #expect(await cancelled.value == 1)
        #expect(await session.ownsHostSession)
        await response.open()
        let cleaned = await TerminationGate.runBounded(seconds: 5) { await twice.wait() }
        #expect(cleaned)
        #expect(await cancelled.value == 2)
    }

    @Test func lateSuccessLeavesAReconnectAlone() async {
        let session = StreamSession()
        let entered = SafetyTestGate()
        let response = SafetyTestGate()
        let cancelled = SafetyTestCounter()
        let launch = Task {
            try await session.launchAndRecordOwnership(client: "client", appID: 1) {
                await entered.open()
                await response.wait()
                return Self.response
            }
        }
        await entered.wait()
        await session.settlePendingLaunch { await cancelled.increment() }
        #expect(await cancelled.value == 1)
        // The user reconnects to the same PC before the abandoned /launch replies.
        let reconnect = StreamSession()
        _ = try? await reconnect.launchAndRecordOwnership(client: "client", appID: 1) { Self.response }
        await response.open()
        _ = await launch.result
        // Without the newer-launch check, the late cancel lands within milliseconds.
        let cancelledAgain = await TerminationGate.runBounded(seconds: 0.5) {
            while await cancelled.value < 2, !Task.isCancelled { try? await Task.sleep(for: .milliseconds(5)) }
        }
        #expect(!cancelledAgain)
        #expect(await cancelled.value == 1)
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
        #expect(session.terminationStopBoundSeconds == 4)
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
        let cancelled = SafetyTestCounter()
        await session.settlePendingLaunch { await cancelled.increment() }
        #expect(await cancelled.value == 0)
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

    private static var response: LaunchResponse {
        LaunchResponse(sessionURL: "", gcmKey: Data(), gcmKeyId: Data())
    }
}

private extension StreamSession {
    func prepareLaunchTestSession() { isStreaming = true }

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
