// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  SessionTimerBodyTests.swift
//
//  The overlay timer's tick and the paced present watchdog's episode steps, called directly.
//

import AppKit
import QuartzCore
import Testing
@testable import Glimmer

@MainActor
struct StatsOverlayRefreshTests {

    @MainActor private final class Reads {
        var rows = 0
        var thresholds = 0
    }

    private func attachedOverlay() -> StatsOverlayLayer {
        let overlay = StatsOverlayLayer()
        let video = CALayer()
        video.bounds = CGRect(x: 0, y: 0, width: 1_280, height: 800)
        overlay.attach(to: video)
        return overlay
    }

    private func tick(
        _ refresh: StatsOverlayRefresh, _ dec: VideoDecoder, _ overlay: StatsOverlayLayer,
        reads: Reads, rows: Set<StatsRow.Kind>
    ) {
        let banner = StreamBannerLayer(anchor: .bottomCenter, accent: NSColor.systemOrange.cgColor)
        refresh.tick(
            dec: dec, overlay: overlay, banner: banner, input: nil,
            rows: { reads.rows += 1; return rows },
            thresholds: { reads.thresholds += 1; return .default })
    }

    @Test func aHiddenHudSkipsTheRowsThresholdsAndLayout() {
        let dec = VideoDecoder()
        let overlay = attachedOverlay()
        let reads = Reads()
        tick(StatsOverlayRefresh(), dec, overlay, reads: reads, rows: [.codec])
        #expect(reads.rows == 0 && reads.thresholds == 0)
        #expect(overlay.rowViews.isEmpty)
        #expect(overlay.videoSize == .zero)
    }

    /// A Settings flip shows on the next tick, without restarting the stream.
    @Test func aShownHudReadsTheRowSetEveryTick() {
        let dec = VideoDecoder()
        dec.statsOverlayEnabled = true
        dec.streamWidth = 1_920
        dec.streamHeight = 1_080
        let overlay = attachedOverlay()
        let reads = Reads()
        let refresh = StatsOverlayRefresh()
        tick(refresh, dec, overlay, reads: reads, rows: [.codec])
        #expect(Set(overlay.rowViews.keys) == [.codec])
        #expect(overlay.videoSize == CGSize(width: 1_920, height: 1_080))
        tick(refresh, dec, overlay, reads: reads, rows: [.latency])
        #expect(Set(overlay.rowViews.keys) == [.latency])
        #expect(reads.rows == 2 && reads.thresholds == 2)
    }

    @Test func thePillWaitsOutTheLaunchGraceThenFlagsRenderLoss() {
        var now = 100.0
        let box = PerceivedHitchBox(now: { now })
        var snap = StreamStatsSnapshot()
        snap.decodedFps = 120
        snap.renderedFps = 90
        #expect(!box.perceivedHitch(snap: snap))
        now = 105.75
        #expect(!box.perceivedHitch(snap: snap))
        now = 106
        #expect(box.perceivedHitch(snap: snap))
        snap.renderedFps = 110
        now = 106.25
        #expect(!box.perceivedHitch(snap: snap))
    }

    /// Late drops that still present something fresh are absorbed jitter, not a felt stutter.
    @Test func aLateDropBurstCountsOnlyWithAPresentGap() {
        var now = 100.0
        let box = PerceivedHitchBox(now: { now })
        var snap = StreamStatsSnapshot()
        snap.presentationLateDrops = 0
        snap.presentationGaps = 0
        _ = box.perceivedHitch(snap: snap)
        now += 6
        snap.presentationLateDrops = 100
        #expect(!box.perceivedHitch(snap: snap))
        now += 0.25
        snap.presentationLateDrops = 110
        snap.presentationGaps = 1
        #expect(box.perceivedHitch(snap: snap))
        now += 0.25
        snap.presentationLateDrops = 111
        snap.presentationGaps = 2
        #expect(!box.perceivedHitch(snap: snap))
    }

    @Test func thePillLatchesOnlyOnSustainedHitching() {
        let banner = StreamBannerLayer(anchor: .bottomCenter, accent: NSColor.systemOrange.cgColor)
        banner.announce = { _ in }
        for _ in 0..<9 { banner.setSustained(true, text: "Stream stuttering") }
        #expect(banner.layer.isHidden)
        banner.setSustained(true, text: "Stream stuttering")
        #expect(!banner.layer.isHidden && banner.displayedText == "Stream stuttering")
    }
}

@MainActor @Suite(.serialized)
struct PacedPresentWatchdogTests {
    private let recorder = InputRecordingBackend()

    private func makeSession() -> (StreamSession, VideoDecoder, ScriptedClock) {
        StreamSession.presentTripsInCluster = 0
        StreamSession.presentTripLastClearedAt = .nan
        let clock = ScriptedClock()
        let decoder = VideoDecoder()
        decoder.backend = recorder
        return (StreamSession(backend: recorder, clock: clock.session), decoder, clock)
    }

    private func live(
        stalled: Bool = false, sinceTick: Double = 0.004, deficitSeconds: Double = 0,
        releasesPerSecond: Double = 120
    ) -> FramePacer.LivenessSnapshot {
        let release = stalled ? 0.3 : 0.004
        return FramePacer.LivenessSnapshot(
            secondsSinceLastTick: sinceTick, secondsSinceLastRelease: release, depth: 2,
            secondsQueueNonEmpty: release, running: true, totalTicks: 5000,
            totalReleases: 4000, streamFrameIntervalSeconds: 1.0 / 120, adaptiveTargetDepth: 1,
            recentTicksPerSecond: 120, recentReleasesPerSecond: releasesPerSecond,
            tickDeficitSeconds: deficitSeconds, expectedTickHz: 120, tickDeficitModeActive: false,
            presentRejectStreak: 0, rendererRefusalSeconds: 0, secondsSinceLastReject: .infinity)
    }

    @Test func anEpisodeClimbsOnItsOwnClockAndAClearStampsTheCluster() {
        let (session, dec, clock) = makeSession()
        session.tickPacedPresentWatchdog(dec: dec, live: live(stalled: true), decodeIdle: 0)
        #expect(session.presentStallSince == clock.seconds)
        #expect(StreamSession.presentTripsInCluster == 1)
        #expect(session.lastPresentRecoveryStage == 1)
        clock.advance(.seconds(2))
        session.tickPacedPresentWatchdog(dec: dec, live: live(stalled: true), decodeIdle: 0)
        #expect(session.lastPresentRecoveryStage == 3)
        #expect(StreamSession.presentTripLastClearedAt == clock.seconds)
        clock.advance(.milliseconds(50))
        session.tickPacedPresentWatchdog(dec: dec, live: live(), decodeIdle: 0)
        #expect(session.lastPresentRecoveryStage == 0)
        #expect(StreamSession.presentTripLastClearedAt == clock.seconds - 0.05)
    }

    @Test func aReTripInsideTheStickyWindowSkipsTheCheapStages() {
        let (session, dec, clock) = makeSession()
        session.tickPacedPresentWatchdog(dec: dec, live: live(stalled: true), decodeIdle: 0)
        session.tickPacedPresentWatchdog(dec: dec, live: live(), decodeIdle: 0)
        #expect(session.presentStallSince == nil)
        #expect(StreamSession.presentTripLastClearedAt == clock.seconds)
        clock.advance(.seconds(2))
        session.tickPacedPresentWatchdog(dec: dec, live: live(stalled: true), decodeIdle: 0)
        #expect(StreamSession.presentTripsInCluster == 2)
        #expect(session.lastPresentRecoveryStage == 3)
        #expect(session.pacingGiveUpCount == 1)
    }

    @Test func aTripLongAfterTheLastClearStartsAFreshCluster() {
        let (session, dec, clock) = makeSession()
        session.tickPacedPresentWatchdog(dec: dec, live: live(stalled: true), decodeIdle: 0)
        session.tickPacedPresentWatchdog(dec: dec, live: live(), decodeIdle: 0)
        clock.advance(.seconds(11))
        session.tickPacedPresentWatchdog(dec: dec, live: live(stalled: true), decodeIdle: 0)
        #expect(StreamSession.presentTripsInCluster == 1)
        #expect(session.lastPresentRecoveryStage == 1)
    }

    @Test func startupGraceHoldsAStallButNotADeadLink() {
        let (session, dec, clock) = makeSession()
        session.presentWatchdogStartedAt = clock.seconds
        session.tickPacedPresentWatchdog(dec: dec, live: live(stalled: true), decodeIdle: 0)
        #expect(session.presentStallSince == nil)
        let dead = live(sinceTick: 0.3)
        session.tickPacedPresentWatchdog(dec: dec, live: dead, decodeIdle: 0)
        session.tickPacedPresentWatchdog(dec: dec, live: dead, decodeIdle: 0)
        #expect(session.lastPresentRecoveryStage == 2)
    }

    /// A tick-deficit outage began at its measured onset, so the give-up lands on the first trip.
    @Test func aTickDeficitIsTimedFromItsMeasuredOnset() {
        let (session, dec, _) = makeSession()
        let collapse = live(deficitSeconds: StreamSession.presentGiveUpThreshold + 0.1, releasesPerSecond: 30)
        session.tickPacedPresentWatchdog(dec: dec, live: collapse, decodeIdle: 0)
        #expect(session.lastPresentRecoveryStage == 3)
        #expect(session.pacingGiveUpCount == 1)
    }
}
