//
//  StreamSession+Watchdog.swift
//
//  The PRESENT-PATH self-heal watchdog: its tuning thresholds, the 20 Hz timer,
//  and the paced / direct per-tick evaluations that keep the screen from ever
//  hard-freezing. Split out of StreamSession.swift to keep each unit focused;
//  see that file for the actor's stored state and lifetime contract.
//
//  The two siblings this file was itself split into - pure moves, to keep each
//  unit under the length limit - are StreamSession+StatsOverlayTimer.swift (the
//  4 Hz overlay updater + perceived-hitch pill) and
//  StreamSession+FrameWatchdog.swift (the frame-DECODE watchdog, the "did the
//  user see a frame?" gate, its decode-only-stall diagnostic, and the teardown
//  path). The trip-flag computation and the staged recovery ladder are in
//  StreamSession+PresentTrip.swift.
//

import Foundation
import AppKit
import os

extension StreamSession {
    // MARK: - Present-path watchdog tuning

    /// Link-dead trip: a 240Hz link should tick every ~4.17ms; no tick for
    /// this long (~60 missed vsyncs at 240Hz) means the CADisplayLink stopped
    /// (a same-screen HDR/VRR/mode switch that posted no didChangeScreen).
    static let presentLinkDeadThreshold: Double = 0.25
    /// Present-FREEZE trip: the present callback is still ticking (the link is
    /// alive), frames are QUEUED, yet NO frame has reached the renderer for this
    /// long - the `due` gate has latched false (a timebase discontinuity) and the
    /// pacer's own starvation failsafe couldn't break it. Same window as
    /// link-dead. This is the ONLY present-stall signal and it is jitter-proof:
    /// it keys on the release clock + tick liveness + a NON-EMPTY queue, never on
    /// how deep the buffer rides. Under zero-loss wifi jitter the FIFO pins full
    /// and late-drops while the pacer keeps releasing ~1 frame/tick (and the
    /// present-loop backoff presents the freshest frame on a hopelessly-late
    /// head), which keeps the release clock fresh - so a full
    /// buffer never trips this; and an EMPTY queue (a wire/decode drought with
    /// nothing to release) never trips it either - droughts are the RFI/decode
    /// machinery's to recover, not a present wedge. Only a genuine screen freeze
    /// on a ticking link (the 4K240 HDR timebase wedge) holds queued
    /// frames for 0.25s with zero releases.
    static let presentStallThreshold: Double = 0.25
    /// After escalation has run and still no present has resumed within this
    /// long, fall back to direct enqueue (graceful degradation) so we never
    /// hard-freeze. Generous vs the trip thresholds so a transient hiccup that
    /// the cheaper steps fix doesn't disable pacing prematurely.
    static let presentGiveUpThreshold: Double = 2.0
    /// After a give-up (stage 3) drops us to direct enqueue, RE-ENABLE pacing
    /// once decode + direct-present have been continuously healthy for this long.
    /// A give-up over a lossy VPN is usually a one-off drought (a flush-to-IDR
    /// whose IDR was itself delayed), not a wedged present path - so we restore
    /// the buttery pacing rather than losing it for the whole session. The fresh
    /// FramePacer is built clean (no stale cadence/link), so the restore can't
    /// inherit the discontinuity that tripped the give-up.
    ///
    /// THERE IS NO GIVE-UP BUDGET. The watchdog runs continuously for the whole
    /// session and NEVER permanently disables anything (the governing principle:
    /// safeguards are DYNAMIC and continuously recovering, never a one-way kill
    /// switch). A truly-wedged path is handled by the mode-agnostic freeze
    /// recovery - flush / layer-rebuild / IDR - which covers BOTH modes; it does
    /// not need a one-way latch to direct enqueue. A transient drought costs one
    /// restore cycle and the buttery pacing returns on its own.
    static let presentPacingReenableHealthySeconds: Double = 5.0
    /// Direct-path present-stall trip: in direct (no-pacer) mode, decode is
    /// healthy (recordDecodedFrame advancing) but nothing has reached the
    /// renderer for this long. Same window as the paced present-stall trip - a
    /// real screen freeze the watchdog must self-heal regardless of mode. This is
    /// the detector the direct path was missing (the proximate cause of the
    /// "fps_rendered=0 for 17s, no recovery" freeze).
    static let directPresentStallThreshold: Double = 0.4
    // The TICK-DEFICIT trip thresholds (`tickDeficitTripSeconds`,
    // `tickDeficitReleaseRatio`) live in StreamSession+PresentTrip.swift with
    // `evaluatePresentTrip`, their only consumer.
    /// Startup grace: don't trip the present-stall branch of the watchdog until
    /// the pacer has had a moment to LOCK CADENCE after the window comes up -
    /// measured as wall-clock since the watchdog armed (`presentWatchdogStartedAt`),
    /// NOT the literal never-released-a-frame case. The pacer force-releases its
    /// very first frame immediately, so a grace keyed on `totalReleases == 0`
    /// expired the instant frame 1 presented - long before cadence converged -
    /// and then tripped on the pacer's own buffer-priming. 3s spans the priming +
    /// PTS-median convergence so startup no longer cycles disable/re-enable. The
    /// link-dead branch stays active throughout (a truly dead link IS a freeze).
    static let presentWatchdogGrace: Double = 3.0

    /// Install the PRESENT-PATH self-heal watchdog. Runs at 20 Hz on the main
    /// run loop, independent of the decode-output watchdog above. The decode
    /// watchdog is structurally blind to a stall DOWNSTREAM of VideoToolbox (a
    /// stopped CADisplayLink, or the `due` gate latching false on a timebase
    /// discontinuity) because `recordDecodedFrame()` keeps advancing while the
    /// screen is frozen - exactly the 4K240 HDR hard-freeze. This
    /// watchdog gates on the pacer's PRESENT-side liveness and escalates so the
    /// present path can never hard-freeze:
    ///
    ///   Stage 1 (gate wedged, link ticking): force-release the next tick.
    ///   Stage 2 (link dead, no ticks): direct-drain freshest + rebuild link.
    ///   Stage 3 (still stalled past give-up): disable pacing, revert to
    ///           direct enqueue + request an IDR (graceful degradation).
    func startPresentWatchdog() async {
        let dec = videoDecoder
        await MainActor.run {
            self.presentWatchdogTimer?.invalidate()
            self.presentStallSince = nil
            self.directPresentStallSince = nil
            self.lastPresentRecoveryStage = 0
            self.pacingDisabledSince = nil
            self.pacingGiveUpCount = 0
            self.lastWatchdogTotalTicks = 0
            self.sawLinkSilentLastTick = false
            // Re-seed the sticky-ladder cluster memory (static - see the
            // PresentTrip extension): no cross-session trip-history leaks.
            StreamSession.presentTripLastClearedAt = .nan
            StreamSession.presentTripsInCluster = 0
            // Stamp the startup-grace origin: the present-stall branch is
            // suppressed for `presentWatchdogGrace` seconds from here, spanning
            // the pacer's cadence-lock after its first frame.
            self.presentWatchdogStartedAt = CFAbsoluteTimeGetCurrent()
            // 20 Hz (50ms) so we detect and recover a present-path stall in
            // well under the ~300ms a user would perceive as a freeze, while
            // staying a featherweight check (one lock-guarded snapshot read).
            let timer = Timer.scheduledTimer(
                withTimeInterval: 0.05, repeats: true
            ) { [weak self, weak dec] _ in
                MainActor.assumeIsolated {
                    guard let self, let dec else { return }
                    self.tickPresentWatchdog(dec: dec)
                }
            }
            timer.tolerance = 0.01
            self.presentWatchdogTimer = timer
        }
    }

    /// One present-watchdog evaluation. MainActor-isolated (the timer body
    /// runs there). Reads the pacer liveness snapshot and escalates recovery.
    @MainActor
    private func tickPresentWatchdog(dec: VideoDecoder) {
        // Intentional non-presentation is NOT a freeze. When the window is
        // hidden / occluded / backgrounded the present path is deliberately
        // suppressed: frames legitimately stop reaching the screen while decode
        // stays healthy - which is exactly this watchdog's stall signature, and
        // the reason IDRs/RFIs used to storm while the window was unfocused (the
        // link-dead branch in paced mode after orderOut, and tickDirectPresentWatchdog
        // continuously in direct mode). Bail and clear the stall-detection state
        // so it re-arms clean on refocus; the suppressed->false resync in
        // setPresentSuppressed owns the single clean-repaint IDR. This
        // present-watchdog IDR is gated to match the backlog-overflow path.
        if dec.presentSuppressed {
            self.presentStallSince = nil
            self.directPresentStallSince = nil
            self.lastPresentRecoveryStage = 0
            self.sawLinkSilentLastTick = false
            self.lastWatchdogTotalTicks = 0
            return
        }
        // Decode must be healthy for a present-path stall to be the cause; if
        // decode itself is silent the decode-output watchdog owns recovery. The
        // direct branch gates on this decodeIdle explicitly; the paced branch
        // enforces it STRUCTURALLY via the `depth > 0` term in evaluatePresentTrip
        // (queued frames ARE the proof decode is delivering). Gating the paced
        // trip on decodeIdle instead would let a mid-episode wire drought on a
        // jittery link falsely "recover" a genuine wedge (the queue stays full
        // while decode pauses), double-counting present_stall_total and resetting
        // the stage-3 give-up clock every drought.
        let decodeIdle = dec.secondsSinceLastDecodedFrame()
        guard decodeIdle.isFinite else { return }

        guard let live = dec.pacingLiveness(), live.running else {
            // DIRECT (no-pacer) mode. This branch used to be a blind spot - it
            // assumed the direct path "can't wedge the way the pacer can" and
            // only tried to re-enable pacing. That false assumption is the
            // proximate cause of the unrecovered freeze: the direct
            // AVSampleBufferDisplayLayer CAN hard-fail (.status==.failed), and
            // once it does, decode stays healthy (fps_decoded ~143) while NOTHING
            // reaches the screen (fps_rendered=0) with no detector and no
            // recovery. The watchdog now watches the direct present path too,
            // using the MODE-AGNOSTIC present clock (advances on every
            // renderer.enqueue in both modes), and self-heals.
            self.tickDirectPresentWatchdog(dec: dec, decodeIdle: decodeIdle)
            // Continuously try to RESTORE the adaptive pacer once the direct path
            // has been healthy long enough - the jitter safeguard returns on its
            // own (no budget gate; the controller is always running).
            self.maybeReenablePacing(dec: dec, decodeIdle: decodeIdle)
            return
        }
        // Paced mode is live again - clear any direct-stall episode state.
        self.directPresentStallSince = nil

        // Startup grace: suppress the PRESENT-STALL branch while the pacer locks
        // cadence - keyed on TIME since the watchdog armed, not totalReleases==0.
        // The pacer force-releases frame 1 immediately, so a totalReleases-keyed
        // grace expired before cadence converged and then tripped on the pacer's
        // own buffer-priming (the 3× disable/re-enable cycling). The link-dead
        // branch below stays ACTIVE during grace - a truly dead link is still a
        // freeze we must self-heal - only the buffer-priming false trip is
        // suppressed.
        let inStartupGrace: Bool = {
            guard let started = self.presentWatchdogStartedAt else { return false }
            return CFAbsoluteTimeGetCurrent() - started < StreamSession.presentWatchdogGrace
        }()

        let trip = self.evaluatePresentTrip(live: live, inStartupGrace: inStartupGrace)
        guard trip.tripped else {
            // Healthy present path - clear the episode state. Stamp the sticky
            // cluster clock: a NEW trip inside the sticky window of this clear
            // is the same underlying condition re-tripping after a half-heal,
            // and jumps straight to stage-3 giveup instead of re-climbing the
            // ladder (the per-episode reset turned one measured collapse into
            // a ~4.5s three-trip outage). See the PresentTrip extension.
            if self.presentStallSince != nil {
                self.log.notice("Present path recovered - resuming normal pacing")
                StreamSession.presentTripLastClearedAt = CFAbsoluteTimeGetCurrent()
            }
            self.presentStallSince = nil
            self.lastPresentRecoveryStage = 0
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        if self.presentStallSince == nil {
            self.presentStallSince = now
            self.lastPresentRecoveryStage = 0
            // Sticky-ladder cluster bookkeeping: a trip inside the window of
            // the last clear continues the cluster, else starts fresh.
            let sinceClear = now - StreamSession.presentTripLastClearedAt
            if sinceClear.isFinite, sinceClear >= 0,
               sinceClear < StreamSession.presentTripStickyWindowSeconds {
                StreamSession.presentTripsInCluster += 1
            } else {
                StreamSession.presentTripsInCluster = 1
            }
            TelemetryCounters.shared.presentStallTotal.increment()
            // NOTICE, not WARNING: this is a RECOVERABLE degradation the watchdog
            // self-heals, not a crisis. The genuine hard-freeze (decode-silent,
            // frameWatchdogTimeout) stays error-level.
            self.log.notice(
                // swiftlint:disable:next line_length
                "Present-path stall detected - linkDead=\(trip.linkDead, privacy: .public) tickDeficit=\(trip.tickDeficit, privacy: .public) rendererRejecting=\(trip.rendererRejecting, privacy: .public) rendererStarved=\(trip.rendererStarved, privacy: .public) rejectStreak=\(live.presentRejectStreak, privacy: .public) sinceTick=\(live.secondsSinceLastTick * 1000, privacy: .public)ms sinceRelease=\(live.secondsSinceLastRelease * 1000, privacy: .public)ms ticks/s=\(live.recentTicksPerSecond, privacy: .public) releases/s=\(live.recentReleasesPerSecond, privacy: .public) depth=\(live.depth, privacy: .public) decodeIdle=\(decodeIdle * 1000, privacy: .public)ms clusterTrips=\(StreamSession.presentTripsInCluster, privacy: .public) - self-healing")
            Diag.info(
                "Present-path stall detected (linkDead=\(trip.linkDead) "
                + "tickDeficit=\(trip.tickDeficit) "
                + "rendererRejecting=\(trip.rendererRejecting) "
                + "rendererStarved=\(trip.rendererStarved) "
                + "rejectStreak=\(live.presentRejectStreak) "
                + "ticks/s=\(String(format: "%.1f", live.recentTicksPerSecond)) "
                + "releases/s=\(String(format: "%.1f", live.recentReleasesPerSecond)) "
                + "depth=\(live.depth) clusterTrips=\(StreamSession.presentTripsInCluster)); self-healing",
                "Stream")
        }
        // A tick-deficit trip's outage began at the MEASURED deficit onset, not
        // at trip time - feed the ladder the real duration so stage 3 (the
        // proven governor-collapse cure) lands within ~one watchdog beat.
        var stalledFor = now - (self.presentStallSince ?? now)
        if trip.tickDeficit {
            stalledFor = max(stalledFor, live.tickDeficitSeconds)
        }
        self.escalatePresentRecovery(dec: dec, trip: trip, stalledFor: stalledFor)
    }

    // PresentTrip + `evaluatePresentTrip` + `escalatePresentRecovery` (the
    // trip-flag computation and the staged self-heal for a genuine present
    // freeze) live in StreamSession+PresentTrip.swift to keep this file under the
    // length limit.

    /// Present-path freeze detection in DIRECT (no-pacer) mode. The pacer-side
    /// branch of `tickPresentWatchdog` reads only the pacer's LivenessSnapshot,
    /// which is nil here - so without this the direct path had ZERO freeze
    /// detection (the bug). We gate on the MODE-AGNOSTIC present clock instead:
    /// decode is healthy (recordDecodedFrame still advancing) but nothing has
    /// reached the renderer for `directPresentStallThreshold` → the direct
    /// AVSampleBufferDisplayLayer wedged (typically `.status==.failed`), so
    /// self-heal regardless of mode (flush / rebuild-if-failed / IDR). Latched on
    /// `directPresentStallSince` so we fire recovery ONCE per episode, not every
    /// 50ms tick, and re-arm after recovery so a persistent wedge escalates again.
    @MainActor
    private func tickDirectPresentWatchdog(dec: VideoDecoder, decodeIdle: Double) {
        // Decode must be healthy for a present freeze to be the cause; if decode
        // is silent the decode-output watchdog owns recovery.
        guard decodeIdle < StreamSession.directPresentStallThreshold else {
            self.directPresentStallSince = nil
            return
        }
        let sincePresent = dec.secondsSinceLastPresentedFrame()
        // .infinity = nothing presented yet (handshake / pre-first-frame). Leave
        // that to the decode-output watchdog; only a STALLED-after-flowing clock
        // is a freeze.
        guard sincePresent.isFinite,
              sincePresent > StreamSession.directPresentStallThreshold else {
            // Present clock advancing → healthy direct path. Clear the episode.
            if self.directPresentStallSince != nil {
                self.log.notice("Direct present path recovered - frames reaching the screen again")
            }
            self.directPresentStallSince = nil
            return
        }

        let now = CFAbsoluteTimeGetCurrent()
        if self.directPresentStallSince == nil {
            self.directPresentStallSince = now
            TelemetryCounters.shared.presentStallTotal.increment()
            self.log.notice(
                // swiftlint:disable:next line_length
                "Direct present-path stall detected - sincePresent=\(sincePresent * 1000, privacy: .public)ms decodeIdle=\(decodeIdle * 1000, privacy: .public)ms - self-healing")
            Diag.info(
                "Direct present-path stall detected (screen frozen while decode healthy); self-healing",
                "Stream")
            // Recover immediately: flush, rebuild the layer if the renderer
            // hard-failed, request an IDR. Re-arm so a persistent wedge fires
            // again next window rather than latching.
            dec.recoverPresentPath(reason: "direct_present_stall")
        } else if now - (self.directPresentStallSince ?? now) >= StreamSession.directPresentStallThreshold {
            // Still stalled a full window after the first recovery attempt -
            // escalate again (e.g. the IDR was itself delayed, or the first flush
            // didn't clear a hard-failed renderer that now will rebuild).
            self.directPresentStallSince = now
            dec.recoverPresentPath(reason: "direct_present_stall_persist")
        }
    }

    // `maybeReenablePacing` (the give-up → warm-handover restore) lives in
    // StreamSession+PresentTrip.swift with the rest of the staged-recovery
    // machinery, keeping this file under the length limit.
}
