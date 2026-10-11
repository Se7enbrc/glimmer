// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  TimedDecisionTests.swift
//
//  Decisions that hang on elapsed time, run on a scripted clock: latency warmup and stages, input
//  age and idle edges, the decode gate, present recovery, display and audio windows, the quit dwell.
//

import AVFoundation
import Foundation
import os
import QuartzCore
import Testing
@testable import Glimmer

/// A hand-moved uptime clock. Its sleep moves it instead of waiting and records each nap; with a
/// `step`, every read lands that much after the one before.
final class ScriptedClock: Sendable {
    private let state: OSAllocatedUnfairLock<(nanos: UInt64, naps: [Duration])>
    private let step: UInt64

    init(startingAt nanos: UInt64 = 1_000_000_000_000, step: Duration = .zero) {
        state = OSAllocatedUnfairLock(initialState: (nanos, []))
        self.step = Self.nanos(step)
    }

    var nanos: UInt64 { state.withLock { $0.nanos } }
    var seconds: Double { Double(nanos) / 1_000_000_000 }
    var napMilliseconds: [Int] { state.withLock { $0.naps.map { Int(($0 / .milliseconds(1)).rounded()) } } }

    func advance(_ duration: Duration) { state.withLock { $0.nanos += Self.nanos(duration) } }

    var now: @Sendable () -> UInt64 {
        { [self] in
            state.withLock { clock in
                defer { clock.nanos += step }
                return clock.nanos
            }
        }
    }

    var session: SessionClock {
        SessionClock(uptimeNanos: now, absolute: { [self] in seconds }, sleep: { [self] nap in
            state.withLock { clock in
                clock.naps.append(nap)
                clock.nanos += Self.nanos(nap)
            }
        })
    }

    static func nanos(_ duration: Duration) -> UInt64 {
        let (seconds, attoseconds) = duration.components
        return UInt64(seconds) * 1_000_000_000 + UInt64(attoseconds / 1_000_000_000)
    }
}

struct TimedLatencyTests {

    /// Onset frames inside 1.25 s of the first present are traced but kept out of the histograms;
    /// the first one past it lands in every stage, glass-to-glass and input-to-photon.
    @Test func presentsPastTheWarmupFillEveryStage() {
        let clock = ScriptedClock()
        let counters = TelemetryCounters()
        counters.setRttMs(10)
        let tracker = FrameTimingTracker(sessionId: "t", now: clock.now, counters: counters)
        func present(_ rtp: UInt32) {
            let received = clock.nanos
            tracker.recordAssembled(rtpTimestamp: rtp, frameIndex: Int32(rtp), receiveNanos: received,
                                    assembleNanos: received + 1_000_000, hostEncodeTenthsMs: 50)
            clock.advance(.milliseconds(3))
            tracker.recordSubmit(rtpTimestamp: rtp)
            clock.advance(.milliseconds(4))
            tracker.recordOutput(rtpTimestamp: rtp)
            clock.advance(.milliseconds(2))
            tracker.recordPresent(rtpTimestamp: rtp)
        }

        present(1)
        clock.advance(.milliseconds(1_200))
        present(2)
        clock.advance(.milliseconds(40))
        counters.noteInputEvent(now: clock.nanos)
        present(3)

        let stages = tracker.histograms
        let expected: [(LatencyHistograms.Stage, Double)] = [
            (stages.receiveToAssemble, 1), (stages.assembleToSubmit, 2), (stages.submitToOutput, 4),
            (stages.outputToPresent, 2), (stages.endToEnd, 9), (stages.decodeP, 4),
            (stages.glassToGlass, 19), (stages.inputToPhoton, 24)
        ]
        for (stage, ms) in expected {
            let snap = stage.snapshot()
            #expect(snap.count == 1)
            #expect(snap.sumMs == ms)
        }
        #expect(stages.decodeIDR.snapshot().count == UInt64.zero)
    }

    /// The input-to-photon estimate counts each input once, however many frames follow it.
    @Test func oneInputFeedsOneInputToPhoton() {
        let clock = ScriptedClock()
        let counters = TelemetryCounters()
        let tracker = FrameTimingTracker(sessionId: "t", now: clock.now, counters: counters)
        func present(_ rtp: UInt32) {
            tracker.recordAssembled(rtpTimestamp: rtp, frameIndex: Int32(rtp), receiveNanos: clock.nanos,
                                    assembleNanos: clock.nanos)
            clock.advance(.milliseconds(5))
            tracker.recordPresent(rtpTimestamp: rtp)
        }
        present(1)
        clock.advance(.seconds(2))
        counters.noteInputEvent(now: clock.nanos)
        present(2)
        present(3)
        #expect(tracker.histograms.inputToPhoton.snapshot().count == 1)
        #expect(tracker.histograms.endToEnd.snapshot().count == 2)
    }

    @Test func idleGapsCountAsIdleToActiveEdges() {
        let counters = TelemetryCounters()
        let gap = ScriptedClock.nanos(.seconds(TelemetryCounters.idleGapSeconds))
        let start: UInt64 = 5_000_000_000
        counters.noteInputEvent(now: start)
        counters.noteInputEvent(now: start + gap - 1)
        #expect(counters.inputIdleToActiveTotal.value == 0)
        let resumed = start + 2 * gap - 1
        counters.noteInputEvent(now: resumed)
        #expect(counters.inputIdleToActiveTotal.value == 1)
        #expect(counters.timeSinceLastInputMs(now: resumed + 250_000_000) == 250)
        #expect(counters.timeSinceLastInputMs(now: resumed - 1) == 0)
    }

    /// Merged motion held back by a stalled reliable channel ages until an edge event drains it.
    @Test func heldMotionReportsItsQueueAgeWhenAnEdgeDrainsIt() throws {
        // Every read is 7 ms after the last: the stamp, then the drain's two reads.
        let clock = ScriptedClock(step: .milliseconds(7))
        let tracker = FrameTimingTracker(sessionId: "t", counters: TelemetryCounters())
        let channel = EnetControlChannel(host: "127.0.0.1", port: 9, controlConnectData: 0,
                                         crypto: try ControlCrypto(rikey: EnetFixture.key))
        channel.reliableBackloggedFlag.store(true, ordering: .relaxed)
        let batcher = InputBatcher(enet: channel, now: { DispatchTime(uptimeNanoseconds: clock.now()) },
                                   tracker: { tracker })
        _ = batcher.accumulateMouseMove(dx: 5, dy: 0)
        _ = batcher.passThrough(
            InputEncoder.mouseButton(action: Int8(StreamProtocol.BUTTON_ACTION_PRESS), button: 1),
            channel: Enet.ctrlChannelMouse)
        batcher.stop()

        let age = tracker.inputLocalLatency.snapshot()
        #expect(age.count == 1)
        #expect(age.sumMs == 14)
        #expect(tracker.lastInputLegsMs == 14)
    }
}

@MainActor @Suite(.serialized)
struct TimedPresentPathTests {

    private let recorder = InputRecordingBackend()

    /// Decode fresh and the screen frozen (or fresh) for the whole test, whatever the real clock does.
    private func decoder(presenting: Bool) -> VideoDecoder {
        let decoder = VideoDecoder()
        decoder.backend = recorder
        decoder.statsCollector.lastDecodedFrameTime = CACurrentMediaTime() + 3_600
        decoder.statsCollector.lastPresentTime = CACurrentMediaTime() + (presenting ? 3_600 : -3_600)
        return decoder
    }

    @Test func aFrozenDirectPresentRecoversOnceThenAgainAfterAFullWindow() {
        let clock = ScriptedClock()
        let session = StreamSession(backend: recorder, clock: clock.session)
        let frozen = decoder(presenting: false)
        session.tickPresentWatchdog(dec: frozen)
        #expect(session.directPresentStallSince == clock.seconds)
        #expect(recorder.idrRequests == 1)

        clock.advance(.milliseconds(375))
        session.tickPresentWatchdog(dec: frozen)
        #expect(recorder.idrRequests == 1)
        clock.advance(.milliseconds(125))
        session.tickPresentWatchdog(dec: frozen)
        #expect(recorder.idrRequests == 2)
        #expect(session.directPresentStallSince == clock.seconds)

        session.tickPresentWatchdog(dec: decoder(presenting: true))
        #expect(session.directPresentStallSince == nil)
        #expect(recorder.idrRequests == 2)
    }

    /// A healthy stream's present metric reaches notice level once a minute, debug in between.
    @Test func aHealthyPresentMetricNoticesOncePerMinute() {
        let clock = ScriptedClock()
        let session = StreamSession(backend: recorder, clock: clock.session)
        let healthy = decoder(presenting: true)
        session.emitPresentMetric(dec: healthy)
        let first = clock.seconds
        #expect(session.lastPresentMetricNoticeTime == first)
        clock.advance(.seconds(59))
        session.emitPresentMetric(dec: healthy)
        #expect(session.lastPresentMetricNoticeTime == first)
        clock.advance(.seconds(1))
        session.emitPresentMetric(dec: healthy)
        #expect(session.lastPresentMetricNoticeTime == clock.seconds)
    }

    /// The gate engages only while hidden, and its lift is timed for the frame watchdog's floor.
    @Test func theDecodeGateEngagesWhileHiddenAndTimesItsLift() {
        let clock = ScriptedClock()
        let decoder = VideoDecoder(now: clock.now)
        defer { decoder.teardown() }
        decoder.attach(to: AVSampleBufferDisplayLayer())
        decoder.setBackend(recorder)
        decoder.isStreaming = true

        decoder.engageDecodeGate()
        #expect(!decoder.decodeGated)
        decoder.setPresentSuppressed(true)
        decoder.engageDecodeGate()
        #expect(decoder.decodeGated)
        #expect(decoder.secondsSinceDecodeGateLifted() == .infinity)

        clock.advance(.seconds(5))
        decoder.setPresentSuppressed(false)
        #expect(!decoder.decodeGated)
        #expect(decoder.secondsSinceDecodeGateLifted() == 0)
        clock.advance(.milliseconds(1_500))
        #expect(decoder.secondsSinceDecodeGateLifted() == 1.5)
    }

    @Test func displaySamplesFoldIntoOneWindowThatResetsOnRead() {
        let headroom = OSAllocatedUnfairLock(initialState: [1.0, 3.0, 2.0])
        let display = DisplayTelemetry(probe: {
            headroom.withLock { left in
                left.isEmpty ? nil : DisplayProbe(edrHeadroom: left.removeFirst(), hdrEngaged: true,
                                                  screenName: "Built-in", proMotionCapable: true, maxRefreshHz: 120)
            }
        })
        for _ in 0..<3 { display.sampleTick() }
        let window = display.snapshotAndReset()
        #expect(window.edrHeadroomMin == 1)
        #expect(window.edrHeadroomAvg == 2)
        #expect(window.edrHeadroomMax == 3)
        #expect(window.state?.edrHeadroom == 2)

        display.sampleTick()
        let quiet = display.snapshotAndReset()
        #expect(quiet.edrHeadroomAvg == nil)
        #expect(quiet.state?.edrHeadroom == 2)
    }

    @Test func aChordStillHeldWhenTheDwellRunsOutQuits() {
        let forwarder = InputForwarder()
        defer { forwarder.detach() }
        forwarder.isReady = true
        forwarder.controllerQuitChordProvider = { .l1r1 }
        var quits = 0
        forwarder.onQuitHotkey = { quits += 1 }
        let analog = InputForwarder.neutralControllerAnalog
        let shoulders = StreamProtocol.LB_FLAG | StreamProtocol.RB_FLAG

        forwarder.armQuitChordDwell(slot: 0) { (shoulders, analog) }
        forwarder.quitChordDwellTask?.cancel()
        forwarder.quitChordDwellExpired(slot: 0, pad: nil) { (StreamProtocol.LB_FLAG, analog) }
        #expect(quits == 0)
        #expect(forwarder.quitChordDwellTask == nil)
        #expect(forwarder.quitChordDwellSlot == nil)

        forwarder.armQuitChordDwell(slot: 1) { (shoulders, analog) }
        forwarder.quitChordDwellTask?.cancel()
        forwarder.quitChordDwellExpired(slot: 1, pad: nil) { (shoulders, analog) }
        #expect(quits == 1)
    }

    /// A chord bouncing on its boundary logs one armed cycle per second, each with its outcome.
    @Test func armBreadcrumbsAreLimitedToOnePerSecond() {
        let forwarder = InputForwarder()
        defer { forwarder.detach() }
        forwarder.quitChordBreadcrumb(.armed, "armed", pad: nil, now: 100)
        #expect(forwarder.quitChordCrumbs.cycleLogged)
        forwarder.quitChordBreadcrumb(.cycle, "cancelled", pad: nil, now: 100.25)
        #expect(!forwarder.quitChordCrumbs.cycleLogged)
        forwarder.quitChordBreadcrumb(.armed, "armed", pad: nil, now: 100.5)
        #expect(!forwarder.quitChordCrumbs.cycleLogged)
        #expect(forwarder.quitChordCrumbs.lastArmAt == 100)
        forwarder.quitChordBreadcrumb(.armed, "armed", pad: nil, now: 101)
        #expect(forwarder.quitChordCrumbs.cycleLogged)
        #expect(forwarder.quitChordCrumbs.lastArmAt == 101)
    }
}

struct TimedAudioReceiveTests {

    private final class SilentSink: NativeAudioSink {
        func initialize(audioConfig: Int32, opus: OpusConfig) -> Int32 { 0 }
        func decodeAndPlay(_ opus: UnsafeRawBufferPointer) {}
        func decodeAndPlayPLC() {}
        func cleanup() {}
    }

    private static func receiver() -> RtpAudioReceiver {
        RtpAudioReceiver(host: .ipv4(.loopback), audioPort: 0, pingPayload: [], audioPacketDuration: 5,
                         opusConfig: RtspHandshakeResult.defaultOpusConfig, audioConfig: 0,
                         audioEncryption: false, aesKey: EnetFixture.key,
                         aesIvId: [UInt8](repeating: 0, count: 16), sink: SilentSink())
    }

    @Test func receiveQualityFoldsOncePerSecondWindow() {
        let receiver = Self.receiver()
        receiver.audioLostInWindow = 3
        receiver.flushAudioMetricsIfDue(now: 5_000_000_000)
        receiver.flushAudioMetricsIfDue(now: 5_999_999_999)
        #expect(receiver.audioLostInWindow == 3)
        receiver.flushAudioMetricsIfDue(now: 6_000_000_000)
        #expect(receiver.audioLostInWindow == 0)
        #expect(receiver.audioMetricsWindowStartNanos == 6_000_000_000)
    }

    @Test func thePendingProbeStopsOnceAudioArrivesOrTheStreamStops() {
        let silent = Self.receiver()
        #expect(silent.audioPendingProbeFired(due: RtpAudioReceiver.audioPendingRecheckSeconds))
        silent.firstRtpReceived.set()
        #expect(!silent.audioPendingProbeFired(due: 630))

        let stopped = Self.receiver()
        stopped.interrupted.set()
        #expect(!stopped.audioPendingProbeFired(due: RtpAudioReceiver.audioPendingRecheckSeconds))
    }
}
