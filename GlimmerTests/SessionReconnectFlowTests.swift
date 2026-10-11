// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  SessionReconnectFlowTests.swift
//
//  A live session's reconnect and downshift episodes against a fake Sunshine and recording
//  engines: what each terminate asks the PC, when it relaunches, retries or ends, and what it says.
//

import Foundation
import os
import Testing
@testable import Glimmer

/// Hands out a recording engine per reconnect attempt; the first `failing` refuse to connect.
final class BackendSupply: Sendable {
    private let made = OSAllocatedUnfairLock(initialState: [InputRecordingBackend]())
    private let failing: Int

    init(failing: Int = 0) { self.failing = failing }

    var backends: [InputRecordingBackend] { made.withLock { $0 } }

    func make() -> StreamingBackend {
        made.withLock { made in
            let backend = InputRecordingBackend(connectFailure: made.count < failing ? .sessionFailed(-1) : nil)
            made.append(backend)
            return backend
        }
    }
}

@Suite(.serialized)
struct SessionReconnectFlowTests {
    private static let appID = 7
    private static let pcRestarted = StreamSession.recoverableTerminationCode

    private struct Live {
        let session: StreamSession
        let sunshine: FakeSunshine
        let supply: BackendSupply
        let clock: ScriptedClock
        let events: AsyncStream<StreamEvent>

        /// Ends the session and returns every event it emitted, in order.
        func finish() async -> [String] {
            await session.stop()
            var seen: [String] = []
            for await event in events { seen.append(SessionReconnectFlowTests.label(event)) }
            return seen
        }
    }

    private func live(
        _ script: [String: [Result<ControlTransport.Response, StreamError>]],
        failing: Int = 0, config: StreamConfig = SessionFlow.config
    ) async -> Live {
        let sunshine = FakeSunshine.scripted(script)
        let supply = BackendSupply(failing: failing)
        let clock = ScriptedClock()
        let session = StreamSession(backend: InputRecordingBackend(), makeNetwork: { sunshine.client($0) },
                                    makeBackend: { supply.make() }, clock: clock.session)
        let events = await session.goLive(server: SessionFlow.pairedPC(), config: config, appID: Self.appID)
        return Live(session: session, sunshine: sunshine, supply: supply, clock: clock, events: events)
    }

    fileprivate static func label(_ event: StreamEvent) -> String {
        switch event {
        case .reconnecting: return "reconnecting"
        case .reconnected: return "reconnected"
        case .connectionTerminated(let code, _): return "terminated(\(code))"
        default: return "other"
        }
    }

    @Test func aDroppedLinkRelaunchesOnAFreshEngineAndResumesInPlace() async throws {
        let live = await live(["serverinfo": [SessionFlow.idle], "launch": [SessionFlow.launched],
                               "cancel": [SessionFlow.cancelled]])
        await live.session.handleHostTerminate(code: StreamSession.deadPeerTerminationCode)

        #expect(live.sunshine.paths == ["serverinfo", "launch"])
        let fresh = try #require(live.supply.backends.first)
        #expect(live.supply.backends.count == 1)
        #expect(fresh.startedServers.map(\.rtspSessionUrl) == [SessionFlow.sessionURL])
        #expect(fresh.idrRequests == 1)
        #expect(await live.session.backend === fresh)
        #expect(await !live.session.isReconnecting)
        #expect(await live.session.reconnectAttempts == 0)
        // Quitting afterwards cancels the game this reconnect launched.
        #expect(await live.finish() == ["reconnecting", "reconnected"])
        #expect(live.sunshine.paths.last == "cancel")
    }

    @Test func aFailedAttemptCancelsItsLaunchAndRetriesOnAnotherEngine() async {
        let live = await live(["serverinfo": [SessionFlow.idle], "launch": [SessionFlow.launched],
                               "cancel": [SessionFlow.cancelled]], failing: 1)
        await live.session.handleHostTerminate(code: StreamSession.deadPeerTerminationCode)

        #expect(live.sunshine.paths == ["serverinfo", "launch", "cancel", "serverinfo", "launch"])
        #expect(live.supply.backends.count == 2)
        #expect(live.supply.backends.map(\.startedServers.count) == [1, 1])
        #expect(await live.finish() == ["reconnecting", "reconnected"])
    }

    /// The PC sent the terminate and no longer runs the game: it ended the session on purpose, so
    /// the stream ends cleanly with no relaunch and no /cancel of whatever runs there now.
    @Test func aPcThatQuitTheGameEndsTheStreamWithoutRelaunching() async {
        let live = await live(["serverinfo": [SessionFlow.idle]])
        await live.session.handleHostTerminate(code: Self.pcRestarted)

        #expect(await !live.session.isStreaming)
        #expect(await live.finish() == ["terminated(0)"])
        #expect(live.sunshine.paths == ["serverinfo"])
        #expect(live.supply.backends.isEmpty)
    }

    /// No answer to the probe means Sunshine is restarting, which a reconnect rides out.
    @Test func aSilentPcIsRiddenOutByAReconnect() async {
        let live = await live(["serverinfo": [.failure(.hostTimedOut), SessionFlow.idle],
                               "launch": [SessionFlow.launched], "cancel": [SessionFlow.cancelled]])
        await live.session.handleHostTerminate(code: Self.pcRestarted)

        #expect(live.sunshine.paths == ["serverinfo", "serverinfo", "launch"])
        #expect(await live.finish() == ["reconnecting", "reconnected"])
    }

    @Test func aTerminateBeforeTheStreamWentLiveIsAFailedConnect() async {
        let live = await live([:])
        await live.session.forgetLiveState()
        await live.session.handleHostTerminate(code: StreamSession.deadPeerTerminationCode)

        #expect(await !live.session.isStreaming)
        #expect(await live.finish() == ["terminated(-1)"])
        #expect(live.sunshine.requests.isEmpty)
    }

    /// Mid-reconnect the PC is streaming another app: someone else has it now, so end without a
    /// takeover, a /cancel or a /launch.
    @Test func aPcRunningAnotherAppMidReconnectEndsTheStreamCleanly() async {
        let live = await live(["serverinfo": [SessionFlow.running(9)]])
        await live.session.handleHostTerminate(code: StreamSession.deadPeerTerminationCode)

        #expect(await live.finish() == ["reconnecting", "terminated(0)"])
        #expect(live.sunshine.paths == ["serverinfo"])
        // The attempt's fresh engine is built before the handshake, but never connects.
        #expect(live.supply.backends.map(\.startedServers.count) == [0])
    }

    /// The backoff ramps 0.8, 1.6, then 2.4 s; once every attempt has failed the stream ends.
    @Test func everyAttemptFailingEndsTheStreamAfterTheCap() async {
        let cap = StreamSession.reconnectAttemptCap
        let live = await live(["serverinfo": [SessionFlow.idle], "launch": [SessionFlow.launched],
                               "cancel": [SessionFlow.cancelled]], failing: cap)
        await live.session.handleHostTerminate(code: StreamSession.deadPeerTerminationCode)

        #expect(live.clock.napMilliseconds == [800, 1_600, 2_400, 2_400, 2_400])
        #expect(live.supply.backends.count == cap)
        #expect(live.sunshine.paths.filter { $0 == "launch" }.count == cap)
        #expect(await !live.session.isStreaming)
        #expect(await live.finish() == ["reconnecting", "terminated(-1)"])
    }

    /// The new connection gets its own first-frame allowance, counted from the resume.
    @Test func aResumeRearmsTheFrameWatchdogAtTheResume() async {
        let live = await live(["serverinfo": [SessionFlow.idle], "launch": [SessionFlow.launched],
                               "cancel": [SessionFlow.cancelled]])
        await live.session.handleHostTerminate(code: StreamSession.deadPeerTerminationCode)

        #expect(live.clock.napMilliseconds == [800])
        #expect(live.session.frameWatchdogArmedAt == live.clock.seconds)
        #expect(await live.finish() == ["reconnecting", "reconnected"])
    }

    // MARK: - Frame watchdog

    /// A connection that never decodes a frame ends ten seconds after the arm, not before, with a
    /// bring-up error (no traffic or no frame, by the process-wide datagram clock) instead of -1.
    @Test func aConnectionThatNeverDecodesEndsTenSecondsAfterTheArm() async throws {
        let live = await live([:])
        let decoder = try #require(await live.session.videoDecoder)
        live.session.frameWatchdogArmedAt = live.session.uptimeSeconds
        live.clock.advance(.milliseconds(9_500))
        live.session.frameWatchdogTick(decoder: decoder)
        #expect(await live.session.isStreaming)

        live.clock.advance(.seconds(1))
        live.session.frameWatchdogTick(decoder: decoder)
        var seen: [String] = []
        for await event in live.events { seen.append(Self.label(event)) }
        #expect(seen == ["terminated(-100)"] || seen == ["terminated(-101)"])
        #expect(await !live.session.isStreaming)
    }

    // MARK: - Downshift

    @Test func aRemoteStallDownshiftsAndReconnectsAtTheLowerRate() async throws {
        var config = SessionFlow.config
        config.bitrateKbps = 84_000
        config.remoteness = .remote
        let live = await live(["serverinfo": [SessionFlow.idle], "launch": [SessionFlow.launched],
                               "cancel": [SessionFlow.cancelled]], config: config)
        await live.session.markRemotePath()
        await live.session.considerBitrateDownshift(decodeIdle: 25, receiveIdle: 0.2)

        let fresh = try #require(live.supply.backends.first)
        #expect(fresh.startedConfigs.map(\.bitrate) == [50_400])
        #expect(live.sunshine.paths == ["serverinfo", "launch"])
        #expect(await live.session.reconnectConfig?.bitrateKbps == 50_400)
        #expect(await live.session.downshift.stepsDown == 1)
        #expect(await live.session.bannerText() == "Weak connection. Lowering quality to 50 Mbps…")
        #expect(await live.finish() == ["reconnecting", "reconnected"])
    }

    /// A LAN that can't carry its rate is a different fault: no lower ask, no reconnect.
    @Test func aLanStallNeverDownshifts() async {
        var config = SessionFlow.config
        config.bitrateKbps = 84_000
        let live = await live([:], config: config)
        await live.session.considerBitrateDownshift(decodeIdle: 25, receiveIdle: 0.2)

        #expect(await live.session.reconnectConfig?.bitrateKbps == 84_000)
        #expect(await !live.session.downshift.isDownshifted)
        #expect(live.supply.backends.isEmpty)
        #expect(await live.finish().isEmpty)
        #expect(live.sunshine.requests.isEmpty)
    }
}

private extension StreamSession {
    /// A session that reached its live state: subsystems up, a bridge carrying the event stream.
    func goLive(server: ServerInfo, config: StreamConfig, appID: Int) async -> AsyncStream<StreamEvent> {
        isStreaming = true
        reachedLiveState = true
        reconnectServer = server
        reconnectConfig = config
        reconnectAppID = appID
        let (window, input, decoder) = await MainActor.run {
            (StreamWindow(displayMode: .window), InputForwarder(), VideoDecoder())
        }
        self.window = window
        self.input = input
        videoDecoder = decoder
        let bridge = StreamBridgeContext(session: self, videoDecoder: decoder, audioDecoder: audioDecoder,
                                         inputForwarder: input)
        let (stream, continuation) = AsyncStream<StreamEvent>.makeStream()
        bridge.eventContinuation = continuation
        self.bridge = bridge
        return stream
    }

    func forgetLiveState() { reachedLiveState = false }

    func markRemotePath() { isRemotePathSession = true }

    func bannerText() async -> String? {
        let window = window
        return await MainActor.run { window?.reconnectBanner.displayedText }
    }
}
