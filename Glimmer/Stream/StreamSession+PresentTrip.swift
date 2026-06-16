//
//  StreamSession+PresentTrip.swift
//
//  The present-path watchdog's trip-flag computation and staged recovery.
//  Split out of StreamSession+Watchdog.swift to keep each unit focused and
//  under the file-length limit. `evaluatePresentTrip` classifies one watchdog
//  evaluation (link-dead / genuine present-freeze) and `escalatePresentRecovery`
//  runs the staged self-heal for a tripped episode. Called only from
//  `tickPresentWatchdog` in StreamSession+Watchdog.swift.
//
//  JITTER REGRESSION FIX (root-caused on a clean-but-jittery wifi link): the
//  old #2 "callback throttled" trip keyed on buffer depth (`depth >= maxQueuedFrames`)
//  + late-drops, which is the NORMAL signature of healthy jitter absorption
//  (the #3 FecHeadroomController deepens the buffer 24→48ms, so the FIFO
//  legitimately fills and drop-to-newest late-drops under zero-loss wifi
//  jitter). It mis-fired 98× on a clean-but-jittery link, its self-heal
//  (force-release → rebuildLink) re-seeded the cadence and tripped the
//  present_stall give-up that disabled the pacer for ~5s of unpaced direct
//  presentation each - turning recoverable jitter into hard hitches. FIX #1
//  (pinning `preferredFrameRateRange` to stream Hz) already PREVENTS the OS
//  from throttling the callback below cadence, so the throttle trip is
//  redundant; it is REMOVED. The remaining present-freeze trip is jitter-proof:
//  it keys ONLY on the present callback genuinely not releasing ANY frame while
//  the link is still ticking and the queue holds frames TO release - never on
//  how deep the buffer rides or on late-drop count.
//

import Foundation
import os

extension StreamSession {
    /// The set of present-path stall conditions this watchdog evaluation found.
    /// `tripped` is the disjunction the caller gates recovery on; the individual
    /// flags select the escalation path (drain+rebuild for a dead link,
    /// force-release→drain+rebuild for a wedged-but-ticking gate). There is NO
    /// buffer-depth trip - a full/late-dropping FIFO while the callback ticks and
    /// frames keep releasing is HEALTHY jitter absorption, not a stall - and no
    /// EMPTY-queue trip either: a drought with nothing queued to release belongs
    /// to the RFI/decode machinery, not the present watchdog.
    struct PresentTrip {
        let linkDead: Bool
        let presentStalled: Bool
        /// Partial-rate tick collapse: ticks measurably collapsed AND releases
        /// also collapsed, sustained - the class `presentStalled` is blind to
        /// because 13-58 releases/s keeps the release clock perpetually fresh.
        let tickDeficit: Bool
        /// The gate is releasing but the RENDERER keeps refusing the frames
        /// (a measured consecutive willPresent-false streak - the wired wedge:
        /// drops_backpressure +110/s, releases 0/s, healthy 240/s ticks,
        /// depth 1, SURVIVED the in-ladder link rebuild).
        /// Selects the renderer medicine (flush via recoverPresentPath) for
        /// the cheap stages instead of cadence/link medicine that cannot
        /// touch a latched `isReadyForMoreMediaData`. Never a trip condition
        /// on its own - it only re-aims recovery inside a tripped episode.
        let rendererRejecting: Bool
        var tripped: Bool { linkDead || presentStalled || tickDeficit }
    }

    // MARK: - Sticky recovery-ladder state (cluster memory across episodes)
    //
    // The ladder used to reset per-episode: a recurring underlying condition
    // (the governor still throttling) produced repeated trip → stage-1/2
    // half-heal → re-trip cycles 2s apart, each resetting `presentStallSince`
    // before the 2.0s give-up could fire - one measured episode rode that loop
    // into a ~4.5s outage and 443 late drops while the empirically-optimal
    // response (stage-3 direct present) was never reached. The cluster memory
    // below makes the SECOND trip within the sticky window jump straight to
    // stage 3. Static stored properties because extensions cannot add instance
    // storage and the state's single home (StreamSession.swift) is outside this
    // unit's scope; safe process-wide for the same reason
    // `FramePacer.lastTickTargetTimestamp` is - exactly one streaming session
    // exists at a time, and `startPresentWatchdog` re-seeds both fields.
    //
    // JITTERY-LINK SAFETY: stickiness changes only the RESPONSE to repeated
    // ACTUAL trips - the trip conditions themselves stay jitter-proof
    // (release-silence / dead-link / measured tick+release collapse, never
    // depth or late-drop count). Two genuine trips inside 10s cost a ~5s spell
    // of direct presentation (proven clean: renders==received, 0 late drops in
    // the measured giveup phase) followed by the warm re-enable - never a
    // permanent disable.

    /// Wall-clock of the last episode CLEAR (healthy recovery or giveup).
    /// `.nan` = no prior episode this session.
    @MainActor static var presentTripLastClearedAt: CFAbsoluteTime = .nan
    /// Trips observed inside the rolling sticky window. 1 = fresh episode.
    @MainActor static var presentTripsInCluster: Int = 0
    /// A new trip within this many seconds of the last clear continues the
    /// cluster instead of starting fresh. ~10s spans the measured re-trip
    /// cadence (2s apart) with margin, while two genuinely independent wedges
    /// (e.g. two screen-mode switches minutes apart) never cluster.
    static let presentTripStickyWindowSeconds: Double = 10.0

    /// TICK-DEFICIT trip: the pacer's MEASURED realized tick rate has been in
    /// deficit (<0.5× expected, hysteresis-latched in FramePacer) for this long
    /// with frames queued AND releases also collapsed. 1.75s sits just inside
    /// the 2.0s give-up threshold: the trip's stalledFor is fed from the deficit
    /// duration, so the proven stage-3 cure (direct present) lands ~2s after
    /// collapse onset - versus a measured 6s partial collapse (469 late drops,
    /// input active throughout) that the release-clock trip never saw.
    /// Comfortably above any healthy-jitter window: a deficit needs HALF the
    /// expected callbacks missing for SEVEN consecutive 250ms windows, which
    /// zero-loss wifi jitter (a network-side signal; ticks are display-side)
    /// cannot produce.
    static let tickDeficitTripSeconds: Double = 1.75
    /// Release-rate collapse term of the tick-deficit trip, as a fraction of
    /// the expected tick rate. The in-pacer degraded mode holds releases at
    /// ≈stream rate when it works, so requiring releases <0.5× expected makes
    /// this trip fire ONLY when that first-line failsafe failed too - the
    /// watchdog never tears down a pacer whose degraded mode is presenting fine.
    static let tickDeficitReleaseRatio: Double = 0.5
    /// Consecutive renderer rejections before a tripped episode is classed
    /// `rendererRejecting`. 8 in a row ≈ 46ms of continuous refusal at 172fps
    /// - far past the transient single-frame `isReadyForMoreMediaData` flips
    /// healthy operation produces (any success resets the streak), and by the
    /// time a presentStalled trip can even fire (0.25s of zero releases) a
    /// genuinely latched renderer has racked up ~40. Jitter-proof twice over:
    /// the streak is a renderer-side signal network jitter can't move, and it
    /// only ever re-aims recovery INSIDE an episode the jitter-proof trips
    /// already opened.
    static let rendererRejectStreakTrip: Int = 8

    /// Compute the present-path trip flags for one watchdog evaluation. Also
    /// advances the two-tick link-silent tracking state (`sawLinkSilentLastTick`,
    /// `lastWatchdogTotalTicks`) - it MUST run every evaluation, trip or not, so
    /// the link-dead latch stays consistent. MainActor (the watchdog body's actor).
    @MainActor
    func evaluatePresentTrip(
        live: FramePacer.LivenessSnapshot, inStartupGrace: Bool
    ) -> PresentTrip {
        // Link-dead trip requires GENUINELY no ticks across two consecutive
        // watchdog evaluations, not a single wall-clock delta. A fresh pacer's
        // first CADisplayLink ticks after start()/re-enable are delayed and
        // discontinuous, so a single-sample `secondsSinceLastTick > 0.25` would
        // false-trip during the re-prime (the link-dead-during-grace re-trip that
        // burned the give-up budget). Requiring the tick COUNT to be unchanged
        // across two 50ms ticks means we only escalate when the link is truly
        // not ticking - a re-priming link advances totalTicks and clears the latch.
        let linkSilent = live.secondsSinceLastTick > StreamSession.presentLinkDeadThreshold
        let ticksUnchanged = self.lastWatchdogTotalTicks == live.totalTicks
        let linkDead = linkSilent && ticksUnchanged && self.sawLinkSilentLastTick
        self.sawLinkSilentLastTick = linkSilent
        self.lastWatchdogTotalTicks = live.totalTicks

        // GENUINE present-freeze trip - the ONLY remaining present-stall signal,
        // and it is jitter-proof BY CONSTRUCTION. It fires only when the present
        // callback is still ticking (the link is alive, NOT linkDead), frames are
        // QUEUED, yet NO frame has reached the renderer for a full, jitter-proof
        // window. Crucially it never keys on the buffer being DEEP or on late-drop
        // count: under zero-loss wifi jitter (amplified by the #3
        // FecHeadroomController deepening the buffer 24→48ms) the FIFO
        // LEGITIMATELY pins full and drop-to-newest late-drops some frames WHILE
        // the pacer keeps releasing ~1 frame/tick (and the present-loop backoff
        // presents the freshest frame whenever the head goes hopelessly late) -
        // that keeps `secondsSinceLastRelease` fresh, so a full buffer never
        // trips this.
        //
        // DROUGHT GATE (root-caused on a lossy wifi link): the release clock ALSO
        // goes stale when there is simply nothing to release - a wire-loss
        // drought leaves the queue EMPTY while the link ticks, and that recovery
        // is owned by the RFI/decode machinery, not this watchdog (a real
        // multi-second loss episode tripped this with depth=0: a needless force-release +
        // link rebuild, and present_stall_total - the pacer-fix regression
        // metric - polluted by a non-stall). `depth > 0` excludes the drought BY
        // CONSTRUCTION without blinding the wedge trip: a wedged gate releases
        // NOTHING, so the first frame decode delivers - even trickling in slowly
        // through loss - latches depth at ≥1 until recovery drains it
        // (drop-to-newest replaces the head, never empties), while a healthy
        // pacer releases a queued frame within a tick, keeping the release clock
        // fresh. The gate keys on depth being NON-ZERO, never HIGH - the
        // jitter-misfire direction (the removed #2 trip) stays removed.
        //
        // With frames queued, the release clock only goes stale for the whole
        // window if the `due` gate has latched false AND the pacer's own
        // starvation failsafe (8 ticks ≈ 33ms@240) somehow failed to break it AND
        // the backoff path released nothing - i.e. a real screen freeze on a
        // ticking link (a display timebase-discontinuity wedge), exactly what
        // this trip must self-heal. `secondsSinceLastTick` must be SMALL (the link
        // ticks) so this is mutually exclusive with linkDead; suppressed during
        // startup grace so cadence-lock + buffer-priming can't masquerade as a
        // wedge. `totalReleases > 0` so the pre-first-frame window is owned by the
        // decode-output watchdog, not this one.
        let linkTicking = live.secondsSinceLastTick <= StreamSession.presentLinkDeadThreshold
        let presentStalled =
            !inStartupGrace
            && linkTicking
            && live.depth > 0
            && live.secondsSinceLastRelease > StreamSession.presentStallThreshold
            && live.totalReleases > 0

        // TICK-DEFICIT trip - the partial-rate collapse class the two trips
        // above are structurally blind to: the governor throttles the link to
        // 13-58 ticks/s against a ~120fps stream, so the link is "ticking"
        // (not linkDead) and a trickle of releases keeps the release clock
        // fresh (not presentStalled), while the user eats a multi-second slog
        // of late-drop slaughter (one measured 6s episode: 469 late drops,
        // input active at ~102 ev/s, zero recovery). Keys ONLY on the pacer's
        // MEASURED rates (FramePacer's rolling realized-rate window - actual
        // fault, never inferred), each term load-bearing:
        //   * tickDeficitSeconds sustained - the measured tick rate has been
        //     below 0.5× expected (min(stream Hz, NOMINAL panel Hz), so
        //     fps>refresh setups never read as deficit) for ~the give-up
        //     window. Healthy wifi jitter cannot move this: ticks are a pure
        //     display-side signal and stay at panel rate under network jitter.
        //   * releases ALSO collapsed - the in-pacer degraded mode (off-tick
        //     release) keeps releases ≈ stream rate when it works, so this
        //     watchdog trip fires only when that first-line failsafe did NOT
        //     hold; layered failsafes, each keyed on its own measured fault.
        //   * depth > 0 - a depth-0 host fade with healthy ticks is a drought
        //     (RFI/decode machinery's job): measured fade windows with renders
        //     tracking received stay clean by construction.
        let expectedHz = live.expectedTickHz
        let tickDeficit =
            !inStartupGrace
            && linkTicking
            && live.depth > 0
            && live.totalReleases > 0
            && live.tickDeficitSeconds > StreamSession.tickDeficitTripSeconds
            && expectedHz.isFinite && expectedHz > 0
            && live.recentReleasesPerSecond.isFinite
            && live.recentReleasesPerSecond
                < StreamSession.tickDeficitReleaseRatio * expectedHz

        // RENDERER-REJECTING classification (the renderer-latch wedge): the
        // pacer is releasing - so the gate/cadence machinery is healthy - but a
        // measured run of consecutive frames died at the renderer. Purely a
        // medicine selector for the ladder below; see the PresentTrip field.
        let rendererRejecting =
            live.presentRejectStreak >= StreamSession.rendererRejectStreakTrip

        return PresentTrip(
            linkDead: linkDead, presentStalled: presentStalled, tickDeficit: tickDeficit,
            rendererRejecting: rendererRejecting)
    }

    /// Run the staged present-path recovery for a tripped episode. Stage 3 (past
    /// the give-up window, OR the 2nd trip inside the sticky cluster window)
    /// always wins regardless of trip kind; below that the trip kind selects the
    /// cheaper paced recovery. Each step runs at most once per stage advance; if
    /// it resumes presentation the episode clears next tick.
    @MainActor
    func escalatePresentRecovery(
        dec: VideoDecoder, trip: PresentTrip, stalledFor: Double
    ) {
        // STICKY LADDER: a 2nd trip within the sticky window means the cheaper
        // stages already half-healed this same underlying condition once and it
        // re-tripped - re-climbing from stage 1 is how a measured episode rode
        // three trip/half-heal cycles into a ~4.5s outage. Jump straight to the
        // empirically-optimal giveup (direct present, fully re-enabling later).
        let clusterEscalate = Self.presentTripsInCluster >= 2
        if stalledFor >= StreamSession.presentGiveUpThreshold || clusterEscalate {
            // Stage 3: the cheaper paced-recovery steps didn't resume presentation,
            // so fall back to direct enqueue transiently AND run the mode-agnostic
            // freeze recovery (flush / layer-rebuild-if-failed / IDR) - the direct
            // path is now WATCHED (see tickDirectPresentWatchdog), so the fallback
            // can never become an unrecovered freeze. This is ALWAYS recoverable:
            // there is no budget and no permanent disable. We unconditionally arm
            // the re-enable so the adaptive pacer comes back on a healthy link.
            if self.lastPresentRecoveryStage < 3 {
                self.lastPresentRecoveryStage = 3
                self.pacingGiveUpCount += 1
                let reason = clusterEscalate && stalledFor < StreamSession.presentGiveUpThreshold
                    ? "present_stall_giveup_sticky" : "present_stall_giveup"
                dec.disablePacingFallbackToDirect(reason: reason)
                dec.recoverPresentPath(reason: reason)
                self.presentStallSince = nil
                // A giveup ENDS the episode - stamp the cluster clear-clock so a
                // post-re-enable re-trip inside the window continues the cluster
                // (and goes straight back to direct) instead of starting fresh.
                Self.presentTripLastClearedAt = CFAbsoluteTimeGetCurrent()
                // Always arm the re-enable - the jitter safeguard returns on its
                // own once the direct path is healthy. Never a one-way latch.
                self.pacingDisabledSince = CFAbsoluteTimeGetCurrent()
            }
            return
        }

        if trip.linkDead {
            // Link is dead → "next tick" will never come. Drain the freshest
            // frame straight to the renderer to keep the screen alive, then
            // rebuild the link (which re-seeds the cadence base).
            if self.lastPresentRecoveryStage < 2 {
                self.lastPresentRecoveryStage = 2
                dec.pacingDrainHeadDirectly(reason: "link_dead")
                dec.pacingRebuildLink(reason: "link_dead")
            }
        } else if trip.rendererRejecting {
            // Link ticking, gate RELEASING, renderer REFUSING (the measured
            // consecutive-reject streak - the renderer-latch wedge). The
            // cadence/link medicine below is the wrong organ for this class:
            // in the field the wedge survived forceRelease AND the in-ladder
            // link rebuild, and only the give-up's renderer flush cured it -
            // a ~1s felt freeze that these stages could have ended in ~50ms.
            // Run the mode-agnostic present recovery (flush; rebuild-if-failed;
            // IDR) directly, KEEPING the pacer. Two attempts before the
            // stage-3 give-up; bounded cost per attempt is one flush + one
            // keyframe (8/8 IDR round-trips matched at p50 6ms on the wire),
            // and a transient flip that cleared just before this ran makes the
            // recovery a benign clean repaint - never a teardown.
            if self.lastPresentRecoveryStage < 1 {
                self.lastPresentRecoveryStage = 1
                dec.recoverPresentPath(reason: "renderer_reject")
            } else if self.lastPresentRecoveryStage < 2 {
                self.lastPresentRecoveryStage = 2
                dec.recoverPresentPath(reason: "renderer_reject_persist")
            }
        } else {
            // Link is ticking but the gate is wedged (genuine present freeze on a
            // live link) → force the next tick to release (re-seed the cadence
            // base). Cheapest fix; preserves pacing. Escalates to drain+rebuild if
            // it doesn't resume - `installLink` re-pins `preferredFrameRateRange`
            // (FIX #1) on the rebuilt link, so a stale floor (if any) is restored.
            // A tick-deficit trip takes this branch too (the link IS ticking,
            // partially), but only transits it for ~one watchdog beat: its
            // stalledFor is fed from the MEASURED deficit duration (already at
            // the give-up threshold's doorstep when the trip fires), so stage 3
            // - the proven cure for a governor collapse - lands within ~250ms.
            let cause = trip.tickDeficit ? "tick_deficit" : "gate_wedged"
            if self.lastPresentRecoveryStage < 1 {
                self.lastPresentRecoveryStage = 1
                dec.pacingForceRelease(reason: cause)
            } else if self.lastPresentRecoveryStage < 2 {
                self.lastPresentRecoveryStage = 2
                dec.pacingDrainHeadDirectly(reason: "\(cause)_persist")
                dec.pacingRebuildLink(reason: "\(cause)_persist")
            }
        }
    }

    /// After a stage-3 give-up dropped us to direct enqueue, restore pacing once
    /// the direct path has been continuously healthy for the stability window.
    /// Called from the present-watchdog's no-pacer branch (MainActor). No-op
    /// unless a give-up armed the re-enable (`pacingDisabledSince` set). There is
    /// NO budget - the continuous controller always tries to bring the adaptive
    /// pacer back so the jitter safeguard returns on its own on a healthy link.
    ///
    /// "Healthy" in direct mode = decode is flowing AND frames are reaching the
    /// screen. We require BOTH the decode clock and the MODE-AGNOSTIC present
    /// clock to be advancing: re-enabling the pacer while the direct path is
    /// itself frozen would just hand a wedge to a fresh pacer. Any hiccup on
    /// either clock re-arms the stability window so it measures CONTINUOUS health.
    @MainActor
    func maybeReenablePacing(dec: VideoDecoder, decodeIdle: Double) {
        guard let disabledSince = self.pacingDisabledSince else { return }
        // Decode AND present must both be healthy right now; a hiccup on either
        // re-arms the clock so the window only completes after an UNBROKEN stretch.
        let sincePresent = dec.secondsSinceLastPresentedFrame()
        let presentHealthy =
            sincePresent.isFinite && sincePresent < StreamSession.presentStallThreshold
        if decodeIdle >= StreamSession.presentStallThreshold || !presentHealthy {
            self.pacingDisabledSince = CFAbsoluteTimeGetCurrent()
            return
        }
        let healthyFor = CFAbsoluteTimeGetCurrent() - disabledSince
        guard healthyFor >= StreamSession.presentPacingReenableHealthySeconds else { return }
        // The decoder remembers the driving view from startPacing and rebuilds
        // the CADisplayLink onto the same screen; if the view is gone (window
        // torn down) it leaves direct enqueue in place. The rebuilt pacer comes
        // up in WARM HANDOVER (armed inside reenablePacing): submits keep
        // direct-presenting until the fresh link proves healthy realized ticks,
        // then cut over atomically - the COLD cutover here queued arriving
        // frames against the link's delayed first ticks and re-froze the stream
        // 350ms after a measured re-enable (a felt hitch where the restore was
        // supposed to be invisible).
        if dec.reenablePacing(configuredFps: dec.streamFps) {
            self.pacingDisabledSince = nil
            self.presentStallSince = nil
            self.lastPresentRecoveryStage = 0
            // The re-enabled pacer is FRESH (clean cadence/link, tick count from
            // 0) and must re-prime its CADisplayLink, so reset the link-dead
            // two-tick tracking and give it the same startup grace as a cold start.
            // Otherwise the link-dead branch could trip on the delayed first ticks
            // of the rebuilt link, immediately giving up again and defeating the
            // restore (the link-dead-during-grace re-trip that burned the budget).
            self.lastWatchdogTotalTicks = 0
            self.sawLinkSilentLastTick = false
            self.presentWatchdogStartedAt = CFAbsoluteTimeGetCurrent()
        }
    }
}
