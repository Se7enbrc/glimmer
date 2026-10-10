// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  TelemetryCounterStateTests.swift
//  Counters, gauges, session resets and the connect and audio telemetry state.
//

import Foundation
import Testing
@testable import Glimmer

struct TelemetryCounterStateTests {

    // MARK: - Counter

    @Test func counterAddsResetsAndWrapsInsteadOfTrapping() {
        let counter = TelemetryCounters.Counter()
        #expect(counter.value == 0)
        counter.increment()
        counter.increment(by: 4)
        #expect(counter.value == 5)
        counter.reset()
        #expect(counter.value == 0)
        counter.increment(by: UInt64.max)
        counter.increment(by: 2)
        #expect(counter.value == 1)
    }

    @Test func ignoredControlTypesAreCountedPerTypeUpToSixteenKinds() {
        let counters = TelemetryCounters()
        for type in 0..<16 { counters.noteCtrlIgnored(type: UInt16(type)) }
        counters.noteCtrlIgnored(type: 3)
        counters.noteCtrlIgnored(type: 100)   // a 17th kind is dropped from the map
        #expect(counters.ctrlIgnoredTotal.value == 18)
        let perType = counters.ctrlIgnoredPerType.totals
        #expect(perType.count == CtrlIgnoredPerType.maxTrackedTypes)
        #expect(perType[3] == 2)
        #expect(perType[0] == 1)
        #expect(perType[100] == nil)
        counters.ctrlIgnoredPerType.reset()
        #expect(counters.ctrlIgnoredPerType.totals.isEmpty)
    }

    // MARK: - Gauges

    @Test func gaugesStartEmptyAndReadBackWhatWasSet() {
        let counters = TelemetryCounters()
        #expect(counters.decodeState == nil)
        #expect(counters.packetGap == nil)
        #expect(counters.fecHealth == nil)
        #expect(counters.reorderDisplacement == nil)
        #expect(counters.awdlHelper == nil)
        #expect(counters.audioState == nil)
        #expect(counters.recvJitterMs == 0)
        #expect(counters.rttMs == 0)
        #expect(counters.vtSessionCreateMs == 0)
        #expect(!counters.presentSuppressed)
        #expect(!counters.decodeGated)
        #expect(!counters.pacerTickRealtime)

        counters.setDecodeState(.init(hwDecode: true, codec: "hevc", pixelFormat: "420v",
                                      bitDepth: 10, colorSpaceKey: "bt2020"))
        counters.setPacketGap(.init(p50Us: 1, p95Us: 2, maxUs: 3))
        counters.setFecHealth(.init(fecPercentage: 20, parityMargin: nil))
        counters.setReorderDisplacement(.init(maxMs: 4, maxPackets: 5, holdMs: 6))
        counters.setAWDLHelper(.init(suppressing: true, reSuppressTotal: 2))
        counters.setRecvJitterMs(1.5)
        counters.setRttMs(7.5)
        counters.setVtSessionCreateMs(12)
        counters.setPresentSuppressed(true)
        counters.setDecodeGated(true)
        counters.setPacerTickRealtime(true)

        #expect(counters.decodeState?.codec == "hevc")
        #expect(counters.decodeState?.bitDepth == 10)
        #expect(counters.packetGap?.maxUs == 3)
        #expect(counters.fecHealth?.fecPercentage == 20)
        #expect(counters.fecHealth?.parityMargin == nil)
        #expect(counters.reorderDisplacement?.maxPackets == 5)
        #expect(counters.awdlHelper?.reSuppressTotal == 2)
        #expect(counters.recvJitterMs == 1.5)
        #expect(counters.rttMs == 7.5)
        #expect(counters.vtSessionCreateMs == 12)
        #expect(counters.presentSuppressed)
        #expect(counters.decodeGated)
        #expect(counters.pacerTickRealtime)
    }

    @Test func cruiseGainKeepsTheHighestValueSeenFromOne() {
        let counters = TelemetryCounters()
        #expect(counters.cruiseMaxGain == 1.0)
        counters.noteCruiseGain(0.5)
        #expect(counters.cruiseMaxGain == 1.0)
        counters.noteCruiseGain(2.67)
        counters.noteCruiseGain(1.8)
        #expect(counters.cruiseMaxGain == 2.67)
    }

    @Test func audioBufferFillMinimumIsTakenOnceThenStartsOver() {
        let counters = TelemetryCounters()
        #expect(counters.takeAudioBufferFillMinMs() == nil)
        counters.noteAudioBufferFill(ms: 20)
        counters.noteAudioBufferFill(ms: 5)
        counters.noteAudioBufferFill(ms: 30)
        #expect(counters.takeAudioBufferFillMinMs() == 5)
        #expect(counters.takeAudioBufferFillMinMs() == nil)
    }

    @Test func audioStateRoundTripsItsOptionalFields() {
        let counters = TelemetryCounters()
        counters.setAudioState(.init(bufferFillMs: 18, playoutTargetMs: 20, audioClockDriftMs: nil,
                                     bufferFillMinMs: 4, rePrimeTotal: 2))
        let state = counters.audioState
        #expect(state?.bufferFillMs == 18)
        #expect(state?.audioClockDriftMs == nil)
        #expect(state?.resamplerPpm == 0)
        #expect(state?.rePrimeTotal == 2)
    }

    // MARK: - Input activity

    @Test func inputStampAppearsOnTheFirstEventWithoutCountingAnIdleEdge() {
        let counters = TelemetryCounters()
        #expect(counters.lastInputNanos == nil)
        #expect(counters.timeSinceLastInputMs() == nil)
        counters.noteInputEvent()
        counters.noteInputEvent()
        #expect(counters.lastInputNanos != nil)
        #expect((counters.timeSinceLastInputMs() ?? -1) >= 0)
        #expect(counters.inputIdleToActiveTotal.value == 0)
    }

    @Test func rumbleActivityReportsAgeOnlyAfterAStamp() {
        let rumble = RumbleActivity()
        #expect(rumble.ageMs() == nil)
        rumble.stamp()
        #expect((rumble.ageMs() ?? -1) >= 0)
        rumble.reset()
        #expect(rumble.ageMs() == nil)
    }

    // MARK: - Session resets

    @Test func newSessionZeroesCountersAndGaugesButReconnectKeepsTheCounters() {
        let counters = TelemetryCounters()
        counters.rfiTotal.increment(by: 3)
        counters.videoPacketsTotal.increment(by: 100)
        counters.noteCtrlIgnored(type: 9)
        counters.setRttMs(9)
        counters.setRecvJitterMs(2)
        counters.setPacketGap(.init(p50Us: 1, p95Us: 2, maxUs: 3))
        counters.setFecHealth(.init(fecPercentage: 5, parityMargin: 1))
        counters.noteCruiseGain(3)
        counters.setPresentSuppressed(true)
        counters.setDecodeGated(true)

        counters.anchorConnectStart(now: 500, reconnecting: true)
        #expect(counters.rfiTotal.value == 3)
        #expect(counters.videoPacketsTotal.value == 100)
        #expect(counters.rttMs == 0)
        #expect(counters.recvJitterMs == 0)
        #expect(counters.packetGap == nil)
        #expect(counters.fecHealth == nil)
        #expect(counters.cruiseMaxGain == 3)
        #expect(counters.presentSuppressed)
        #expect(counters.p2.connectStart == 500)

        counters.anchorConnectStart(now: 900, reconnecting: false)
        #expect(counters.rfiTotal.value == 0)
        #expect(counters.videoPacketsTotal.value == 0)
        #expect(counters.ctrlIgnoredTotal.value == 0)
        #expect(counters.ctrlIgnoredPerType.totals.isEmpty)
        #expect(counters.cruiseMaxGain == 1.0)
        #expect(!counters.presentSuppressed)
        #expect(!counters.decodeGated)
        #expect(counters.p2.connectStart == 900)
        #expect(counters.p2.firstConnect == nil)
    }

    @Test func audioFirstPacketIsMeasuredFromTheConnectAnchorOnce() throws {
        let counters = TelemetryCounters()
        counters.recordAudioFirstPacket()
        #expect(counters.audioFirstPacketMs == nil)
        counters.p2.anchorConnectStart(1)
        counters.recordAudioFirstPacket()
        let first = try #require(counters.audioFirstPacketMs)
        #expect(first > 0)
        counters.recordAudioFirstPacket()
        #expect(counters.audioFirstPacketMs == first)
    }

    @Test func audioFirstPacketFallsBackToTheStreamStartAnchor() {
        let counters = TelemetryCounters()
        counters.anchorAudioStreamStart()
        counters.recordAudioFirstPacket()
        #expect((counters.audioFirstPacketMs ?? -1) >= 0)
    }

    // MARK: - Audio arrival gaps

    @Test func arrivalGapsKeepTheLargestGapAndTheOpenOneThenClear() {
        let gaps = AudioArrivalGaps()
        #expect(gaps.takeMaxMs(now: 1_000_000_000) == nil)
        gaps.noteArrival(at: 100_000_000, gapNanos: nil)
        gaps.noteArrival(at: 110_000_000, gapNanos: nil)     // 10 ms
        gaps.noteArrival(at: 150_000_000, gapNanos: nil)     // 40 ms
        gaps.noteArrival(at: 160_000_000, gapNanos: 5_000_000) // supplied gap wins: 5 ms
        #expect(gaps.takeMaxMs(now: 170_000_000) == 40)
        // The take cleared the max; only the 25 ms still open since the last arrival remains.
        #expect(gaps.takeMaxMs(now: 185_000_000) == 25)
        gaps.reset()
        #expect(gaps.takeMaxMs(now: 185_000_000) == nil)
    }

    // MARK: - Audio first-frame context

    @Test func firstClassificationLatchesWarmOrColdAndStaysPut() {
        let warm = AudioTtfContext()
        let record = warm.latchClassifying(pingToRtpMs: 1_500, startup: "a", now: 10)
        #expect(record.ttfClass == "warm")
        #expect(warm.latchClassifying(pingToRtpMs: 9_000, startup: "b", now: 11).startup == "a")
        #expect(warm.latched?.ttfClass == "warm")

        let cold = AudioTtfContext()
        #expect(cold.latchClassifying(pingToRtpMs: 2_001, startup: nil, now: 10).ttfClass == "cold")
        let unknown = AudioTtfContext()
        #expect(unknown.latchClassifying(pingToRtpMs: nil, startup: nil, now: 10).ttfClass == "cold")
        let edge = AudioTtfContext()
        #expect(edge.latchClassifying(pingToRtpMs: 2_000, startup: nil, now: 10).ttfClass == "warm")
    }

    @Test func newSessionRecordsHowLongTheHostSatIdleSinceTheLastStreamEnded() {
        let context = AudioTtfContext()
        context.resetForNewSession(now: 100)
        #expect(context.latchClassifying(pingToRtpMs: 1, startup: nil, now: 100).hostIdleSeconds == nil)
        context.markStreamEnd(now: 200)
        context.resetForNewSession(now: 245)
        #expect(context.latched == nil)
        #expect(context.latchClassifying(pingToRtpMs: 1, startup: nil, now: 245).hostIdleSeconds == 45)
        context.resetForNewSession(now: 150)   // clock behind the stream end: no negative idle
        #expect(context.latchClassifying(pingToRtpMs: 1, startup: nil, now: 150).hostIdleSeconds == nil)
    }

    @Test func cushionSeedSetsTheFloorAndTargetAndCanBeAdjusted() {
        let cushion = AudioCushionTelemetry()
        #expect(cushion.seed == nil)
        #expect(cushion.floorMs == 0)
        cushion.latchSeed(.init(link: "wifi", targetMs: 40, floorMs: 12, fromMemory: true))
        #expect(cushion.seed?.link == "wifi")
        #expect(cushion.floorMs == 12)
        #expect(cushion.seedMs == 40)
        cushion.setFloorMs(15)
        cushion.setSeedMs(50)
        #expect(cushion.floorMs == 15)
        #expect(cushion.seedMs == 50)
        #expect(cushion.seed?.floorMs == 12)
    }

    // MARK: - Lifecycle events

    @Test func disconnectReasonsHaveStableLabels() {
        let labels = [DisconnectReason.none, .userStopped, .hostClosedClean, .hostError, .watchdogStall,
                      .connectFailed, .consumerDropped, .systemSleep].map(\.label)
        #expect(labels == ["none", "user_stopped", "host_closed_clean", "host_error", "watchdog_stall",
                           "connect_failed", "consumer_dropped", "system_sleep"])
    }

    @Test func disconnectCountersTrackEveryReasonButNone() {
        let counters = DisconnectReasonCounters()
        counters.increment(.hostError)
        counters.increment(.hostError)
        counters.increment(.systemSleep)
        counters.increment(.none)
        let totals = Dictionary(uniqueKeysWithValues: counters.snapshot().map { ($0.label, $0.total) })
        #expect(totals.count == 7)
        #expect(totals["host_error"] == 2)
        #expect(totals["system_sleep"] == 1)
        #expect(totals["user_stopped"] == 0)
        #expect(totals["none"] == nil)
    }

    @Test func onlyTheFirstDisconnectReasonSticksAndIsCountedGloballyOnce() {
        let state = TelemetryCounters.P2State()
        #expect(state.disconnectReason == .none)
        #expect(!state.setDisconnectReason(.none))
        #expect(state.countGlobalReasonOnce() == nil)
        #expect(state.setDisconnectReason(.watchdogStall))
        #expect(!state.setDisconnectReason(.userStopped))
        #expect(state.disconnectReason == .watchdogStall)
        #expect(state.countGlobalReasonOnce() == .watchdogStall)
        #expect(state.countGlobalReasonOnce() == nil)
    }

    @Test func handshakeLegsAreMeasuredBetweenTheirMarks() {
        let state = TelemetryCounters.P2State()
        #expect(state.handshakeBreakdown().totalMs == nil)
        state.anchorConnectStart(1_000_000)
        state.anchorConnectStart(9_000_000)   // the first anchor wins
        state.markRtspStart(2_000_000)
        state.markRtspDone(5_000_000)
        state.markEnetStart(6_000_000)
        state.markFirstFrame(21_000_000)
        let breakdown = state.handshakeBreakdown()
        #expect(breakdown.rtspMs == 3)
        #expect(breakdown.controlSetupMs == 1)
        #expect(breakdown.totalMs == 20)
        #expect(breakdown.enetConnectMs == nil)
        #expect(breakdown.complete)
    }

    @Test func aMarkBeforeItsStartLeavesTheLegUnreported() {
        let state = TelemetryCounters.P2State()
        state.markRtspStart(9_000_000)
        state.markRtspDone(4_000_000)
        #expect(state.handshakeBreakdown().rtspMs == nil)
        #expect(!state.handshakeBreakdown().complete)
    }

    @Test func reconnectKeepsTheFirstConnectHandshakeAndRestartsTheClock() {
        let state = TelemetryCounters.P2State()
        state.anchorConnectStart(1_000_000)
        state.markFirstFrame(11_000_000)
        state.setDisconnectReason(.hostError)
        state.anchorReconnect(50_000_000, audioTtfMs: 80, audioTtf: nil)
        state.anchorReconnect(90_000_000, audioTtfMs: 1, audioTtf: nil)
        #expect(state.firstConnect?.handshake.totalMs == 10)
        #expect(state.firstConnect?.handshake.complete == true)
        #expect(state.firstConnect?.audioTtfMs == 80)
        #expect(state.connectStart == 90_000_000)
        #expect(state.disconnectReason == .none)
        #expect(!state.handshakeBreakdown().complete)
        state.reset()
        #expect(state.firstConnect == nil)
        #expect(state.connectStart == 0)
    }

    @Test func idrRoundTripResolvesOncePerRequestAndNeverGoesBackwards() {
        let state = TelemetryCounters.P2State()
        #expect(state.resolveIdrArrival(5_000_000) == nil)
        state.stampIdrRequest(10_000_000)
        #expect(state.resolveIdrArrival(9_000_000) == nil)     // arrival before the request
        #expect(state.resolveIdrArrival(14_500_000) == 4.5)
        #expect(state.resolveIdrArrival(20_000_000) == nil)    // consumed
        #expect(state.lastIdrRoundTripMs == 4.5)
    }

    @Test func launchLegsRecordOnceAndFillTheBreakdownWhenSet() {
        let timing = ConnectTimingTelemetry()
        var empty = HandshakeBreakdown()
        timing.applyLaunchLegs(to: &empty)
        #expect(empty.launchMs == nil)
        #expect(empty.launchBusyPollCount == nil)
        timing.recordLaunchLeg(serverinfoMs: 12, launchBusyWaitMs: 300, busyPollCount: 4, launchMs: 80)
        timing.recordLaunchLeg(serverinfoMs: 99, cancelMs: 7, launchMs: 99, buildMs: 3)
        var filled = HandshakeBreakdown()
        timing.applyLaunchLegs(to: &filled)
        #expect(filled.launchServerinfoMs == 12)
        #expect(filled.launchBusyWaitMs == 300)
        #expect(filled.launchBusyPollCount == 4)
        #expect(filled.launchMs == 80)
        #expect(filled.launchCancelMs == 7)
        #expect(filled.buildMs == 3)
        timing.resetForNewSession()
        var cleared = HandshakeBreakdown()
        timing.applyLaunchLegs(to: &cleared)
        #expect(cleared.launchServerinfoMs == nil)
    }

    @Test func clickToFirstFrameNeedsAClickAnchorFirst() {
        let timing = ConnectTimingTelemetry()
        timing.markConnectStart()
        timing.markFirstFrame()
        #expect(timing.launchPathMs == nil)
        #expect(timing.clickToFirstFrameMs == nil)
    }

    @Test func deliverStampKeepsTheFirstTimePerSlotAndClearsOnTake() {
        let stamp = InputDeliverStamp()
        stamp.stamp(slot: 2, nanos: 100)
        stamp.stamp(slot: 2, nanos: 200)
        stamp.stamp(slot: 15, nanos: 7)
        stamp.stamp(slot: 16, nanos: 9)    // out of range
        stamp.stamp(slot: -1, nanos: 9)
        #expect(stamp.take(slot: 2) == 100)
        #expect(stamp.take(slot: 2) == 0)
        #expect(stamp.take(slot: 15) == 7)
        #expect(stamp.take(slot: 16) == 0)
        #expect(stamp.take(slot: -1) == 0)
    }
}
