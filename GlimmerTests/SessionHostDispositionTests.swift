// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

@testable import GlimmerEngine
import Foundation
import Testing
@testable import Glimmer

@Suite(.serialized)
struct SessionHostDispositionTests {
    @Test(arguments: [0, 7, 9])
    func disconnectOnlyUsesOneCachedLaunchOrResume(runningApp: Int) async throws {
        let sunshine = FakeSunshine.scripted(["launch": [SessionFlow.launched], "resume": [SessionFlow.launched]])
        var server = SessionFlow.pairedPC()
        server.currentGameID = runningApp
        let session = StreamSession(hostDisposition: .disconnectOnly, backend: InputRecordingBackend())
        await session.prepareLaunchFlow(server: server)
        _ = try await session.launchWithDeadline(network: sunshine.client(server), appID: 7,
            config: SessionFlow.config.request, info: server)
        #expect(sunshine.paths == [runningApp == 7 ? "resume" : "launch"])
        await session.settlePendingLaunch { Issue.record("Local disconnect must not cancel an owned launch") }
    }

    @Test(arguments: [StreamError.hostTimedOut, .hostRefused(message: "Busy", code: 503)])
    func failedDisconnectOnlyLaunchNeverEntersCancelRetry(error: StreamError) async {
        let sunshine = FakeSunshine.scripted([
            "launch": [.failure(error), SessionFlow.launched], "serverinfo": [SessionFlow.idle],
            "cancel": [SessionFlow.cancelled]
        ])
        let server = SessionFlow.pairedPC()
        let session = StreamSession(hostDisposition: .disconnectOnly, backend: InputRecordingBackend())
        await session.prepareLaunchFlow(server: server)
        await #expect(throws: StreamError.self) {
            _ = try await session.launchWithDeadline(network: sunshine.client(server), appID: 7,
                config: SessionFlow.config.request, info: server)
        }
        #expect(sunshine.paths == ["launch"])
        await session.settlePendingLaunch { Issue.record("Failed local connection must not cancel") }
    }

    @Test(arguments: [DisconnectReason.userStopped, .hostError, .consumerDropped,
                      .connectFailed, .watchdogStall, .systemSleep, .hostClosedClean])
    func everyLocalStopLeavesTheGameRunning(cause: DisconnectReason) async throws {
        let sunshine = FakeSunshine.scripted(["launch": [SessionFlow.launched]])
        let server = SessionFlow.pairedPC()
        let session = StreamSession(hostDisposition: .disconnectOnly, backend: InputRecordingBackend(),
                                    makeNetwork: { sunshine.client($0) })
        await session.prepareLaunchFlow(server: server)
        _ = try await session.launchWithDeadline(network: sunshine.client(server), appID: 7,
            config: SessionFlow.config.request, info: server)
        await session.stop(cause: cause)
        await session.stop()
        #expect(sunshine.paths == ["launch"])
        #expect(await !session.isStreaming)
        #expect(await !session.stopInProgress)
    }

    @Test func localStopDoesNotWaitForOrCancelLateSuccessfulLaunch() async {
        let session = StreamSession(hostDisposition: .disconnectOnly, backend: InputRecordingBackend())
        await session.prepareLaunchFlow(server: SessionFlow.pairedPC())
        let entered = SafetyTestGate()
        let response = SafetyTestGate()
        let cancellations = SafetyTestCounter()
        let launch = Task {
            try await session.launchAndRecordOwnership(client: "client", appID: 7) {
                await entered.open()
                await response.wait()
                return LaunchResponse(sessionURL: "", gcmKey: Data(), gcmKeyId: Data())
            }
        }
        await entered.wait()
        let finished = await TerminationGate.runBounded(seconds: 0.5) {
            await session.settlePendingLaunch { await cancellations.increment() }
        }
        #expect(finished)
        #expect(await cancellations.value == 0)
        await response.open()
        _ = await launch.result
        await session.settlePendingLaunch { await cancellations.increment() }
        #expect(await cancellations.value == 0)
    }
}
