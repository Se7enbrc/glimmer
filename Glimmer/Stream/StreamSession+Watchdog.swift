//
//  StreamSession+Watchdog.swift
//
//  The stats-overlay update timer and the frame-decode watchdog (the
//  "did the user see a frame?" gate, its decode-only-stall diagnostic, and the
//  teardown path). Split out of StreamSession.swift to keep each unit focused;
//  see that file for the actor's stored state and lifetime contract.
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

    /// Build + install the 4 Hz overlay-update timer (latency rows live; FPS
    /// averaging window decoupled to ~1s via `statsSnapshot(minWindowSeconds:)`).
    /// Captures the decoder and window by weak reference; if either is torn down
    /// between ticks, the timer body no-ops on the next fire and we wait for
    /// `stop()` to invalidate the timer for real.
    func startStatsOverlayTimer(
        statsRowsProvider: @escaping @MainActor () -> Set<StatsRow.Kind>,
        statsThresholdsProvider: @escaping @MainActor () -> StatsThresholds
    ) async {
        // Build a snapshot closure with weak refs. The timer fires on the
        // main run loop; the backend's RTT estimate is safe to read from any
        // thread while the connection is up, so the main thread is fine.
        let dec = videoDecoder
        let win = window
        let inp = input
        // Capture the backend so the overlay tick reads RTT through the
        // protocol (was LiGetEstimatedRttInfo). StreamingBackend is Sendable.
        let backend = self.backend
        await MainActor.run {
            self.statsOverlayTimer?.invalidate()
            // `Timer.scheduledTimer` registers the timer on the *current*
            // run loop. Since we're inside `MainActor.run`, that's the main
            // run loop - exactly where the overlay layer + decoder live.
            // The block closure runs synchronously on the main thread when
            // the timer fires, so `dec` and `win` (both `@MainActor`-
            // isolated) are safe to touch directly.
            // 4 Hz (250ms) overlay refresh so the latency / jitter / RTT rows
            // feel LIVE - at 1Hz a momentary spike was a quarter-second stale.
            // The FPS averaging window stays DECOUPLED from the tick:
            // `statsSnapshot(minWindowSeconds:)` keeps FPS / bitrate / cadence
            // on a ~1s average (the collector slides + recomputes the window
            // only once 1s of data accrues, serving the cached last-good average
            // between), so 4Hz does NOT reintroduce the ±4fps boundary noise a
            // literal 250ms window would; the live gauges refresh at full 4Hz.
            let overlayFpsWindowSeconds = 1.0
            // Per-second-rate baselines for the perceived-hitch pill, carried
            // across ticks. Reference type so the timer closure mutates one box.
            let hitchBox = PerceivedHitchBox()
            let timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak dec, weak win, weak inp] _ in
                MainActor.assumeIsolated {
                    guard let dec, let win else { return }
                    // Cheap stats read FIRST (cached ~1s window) so the pill
                    // works with the HUD off - the expensive host/controller
                    // probes below stay gated on `statsOverlayEnabled`.
                    var snap = dec.statsSnapshot(minWindowSeconds: overlayFpsWindowSeconds)
                    // Auto pill, independent of the stats-HUD toggle so a
                    // degrading PRESENT path reaches the user with the HUD off.
                    // Drives off PERCEIVED present-hitching (render-gap / stale
                    // repeats / late drops), not env_state (which measures link
                    // contention and anti-correlates with felt stutter).
                    let composite = hitchBox.perceivedHitch(snap: snap)
                    win.networkBanner.setSustained(composite, text: "Stream stuttering")
                    // Cheap early-out: if the overlay is hidden, skip the
                    // expensive enrichment + HUD render. The decoder's collectors
                    // keep ticking so a re-enable shows fresh numbers immediately.
                    guard dec.statsOverlayEnabled else { return }
                    // estimatedRtt() returns nil if the engine isn't connected
                    // (very old GFE versions, or a transient drop, or the native
                    // stub). On nil we leave rtt nil and the row renders as "-".
                    // Was LiGetEstimatedRttInfo.
                    if let rttInfo = backend.estimatedRtt() {
                        // RTT is now measured from a HIGH-RES local monotonic clock
                        // (fractional ms, EWMA as Double) - no widen/truncation; the
                        // overlay shows true sub-ms latency uniformly with jitter.
                        snap.rttMs = rttInfo.rttMs
                        snap.rttVarianceMs = rttInfo.varianceMs
                    }
                    // Jitter: prefer the FINE RFC-3550 smoothed receive jitter
                    // (already Double, ~0.09ms on a clean wired link) over the
                    // whole-ms ENet RTT variance - an integer variance rounds a
                    // clean link to "0 ms" (no signal). `recvJitterMs` is the same
                    // gauge the telemetry exporter ships, refreshed by the RTP
                    // receive path. Falls back to the RTT-variance proxy
                    // (rttVarianceMs, set above) only when no fine jitter has been
                    // measured yet (gauge still 0 / pre-first-sample) - the row
                    // resolves `jitterMs ?? rttVarianceMs`.
                    let fineJitter = TelemetryCounters.shared.recvJitterMs
                    if fineJitter > 0 {
                        snap.jitterMs = fineJitter
                    }
                    // Host-Mac vitals (battery, CPU%, RAM%). Probes are
                    // cheap (IOPS + two host_statistics calls) but we
                    // still gate on the overlay being on so a disabled
                    // overlay doesn't keep the sampler ticking.
                    let mac = MacSystemStats.shared.snapshot()
                    snap.macBatteryPercent = mac.batteryPercent
                    snap.macBatteryCharging = mac.batteryCharging
                    snap.macCpuPercent = mac.cpuPercent
                    snap.macRamPercent = mac.ramPercent
                    // Connected controller battery (first attached pad that
                    // reports one). Read live each tick so it tracks a pad
                    // that connects/disconnects mid-stream.
                    if let inp, let batt = inp.currentControllerBattery() {
                        snap.controllerBatteryPercent = batt.percent
                        snap.controllerBatteryCharging = batt.charging
                    }
                    // Read the enabled row set live every tick so a
                    // Settings flip (preset change, custom checkbox
                    // toggle) takes effect on the next 1Hz refresh - no
                    // need to restart the stream to see the new layout.
                    // The provider closure resolves through
                    // MoonlightManager.effectiveStatsRows, which routes
                    // through statsOverlayPreset + statsOverlayCustomRows.
                    let enabled = statsRowsProvider()
                    let thresholds = statsThresholdsProvider()
                    win.statsOverlay.update(
                        snapshot: snap,
                        enabled: enabled,
                        targetFps: Double(dec.streamFps),
                        thresholds: thresholds)
                }
            }
            // Tolerance saves the OS some power - at 4 Hz a 30 ms tolerance is
            // invisible to the user but lets the run loop coalesce the timer.
            // Under half the 250ms interval so a coalesced tick can't drift
            // into the next one.
            timer.tolerance = 0.03
            self.statsOverlayTimer = timer
        }
    }

    /// Install the frame-arrival watchdog. Polls every 1s on the main run
    /// loop; gates on `VideoDecoder.secondsSinceLastDecodedFrame()` so a
    /// host sending us packets we can't decode (corrupt bitstream, missing
    /// IDR, codec mismatch) trips the watchdog instead of leaving the user
    /// staring at a black screen while reception looks healthy.
    func startFrameWatchdog() async {
        let dec = videoDecoder
        await MainActor.run {
            self.frameWatchdogTimer?.invalidate()
            let timer = Timer.scheduledTimer(
                withTimeInterval: 1.0, repeats: true
            ) { [weak self, weak dec] _ in
                guard let dec else { return }
                // GATED ≠ STALLED. While the hidden-window decode gate is
                // engaged the decoder is deliberately fed nothing (receive/
                // RFI and audio keep flowing) - healthy-by-design, the exact
                // mirror of tickPresentWatchdog bailing while suppressed.
                // Bail BEFORE reading the idle clocks so a long gated span
                // can't trip the decode-only diagnostic or the teardown
                // timeout. No trip condition is loosened: an UNGATED decode
                // stall still trips on the unchanged thresholds below. And the
                // gate can never block TEARDOWN: stopConnection's sink-stop
                // clears it (clearDecodeGateForConnectionStop), so a host
                // terminate while the window is hidden still reaches the hard
                // trip below on the normal post-gate envelope.
                if dec.decodeGated { return }
                // After a gate lifts, secondsSinceLastDecodedFrame() still
                // carries the whole gated span - a 60s gate reads as 60s of
                // idle at the very next 1Hz tick, past frameWatchdogTimeout,
                // tearing the session down before the ~12ms resync IDR can
                // decode. Floor the idle clock at the gate-OFF edge instead
                // (infinity when no gate ever engaged, so min() is identity):
                // the watchdog re-arms honestly FROM the resume - a post-gate
                // IDR that genuinely never decodes still soft-trips 3s and
                // hard-trips 10s after refocus, exactly the normal envelope.
                let decodeIdle = min(
                    dec.secondsSinceLastDecodedFrame(),
                    dec.secondsSinceDecodeGateLifted())
                // .infinity means we've never decoded a frame - leave the
                // initial RTSP/IDR window alone. Once decode starts flowing,
                // decodeIdle is a small number; if it climbs past the
                // threshold the host has gone silent or the bitstream is
                // unrecoverable.
                guard decodeIdle.isFinite else { return }
                let receiveIdle = dec.secondsSinceLastReceivedFrame()

                // Soft trip: reception healthy but decode silent → log a
                // public-privacy diagnostic so the user-visible black-
                // screen symptom shows up in the unified log with an
                // actionable cause. Hard trip below still runs.
                if decodeIdle > StreamSession.decodeOnlyStallThreshold,
                   receiveIdle.isFinite,
                   receiveIdle < StreamSession.decodeOnlyStallThreshold {
                    guard let self else { return }
                    Task { [weak self] in
                        await self?.handleDecodeOnlyStall(
                            decodeIdle: decodeIdle, receiveIdle: receiveIdle)
                    }
                } else if decodeIdle < StreamSession.decodeOnlyStallThreshold {
                    // Decode healthy this tick - clear the latch so a
                    // future stall logs a fresh diagnostic.
                    guard let self else { return }
                    Task { [weak self] in await self?.clearDecodeOnlyStallLatch() }
                }

                // ACTIVE RECOVERY: decode silent past the recovery
                // threshold - request an IDR each tick to prompt a host that
                // paused video (e.g. the Windows sign-in → desktop transition)
                // to resume, rather than freezing until a manual reconnect.
                // Covers the host-went-fully-silent case the soft trip above
                // (which needs reception alive) misses. Fires for the WHOLE
                // stall, not just up to frameWatchdogTimeout: when the control
                // link is alive the hard trip below now HOLDS rather than tears
                // down, so we must keep nudging the host for a keyframe past 10s
                // so video resumes promptly once the desktop returns. If frames
                // resume, decodeIdle drops and the latch clears.
                if decodeIdle > StreamSession.decodeStallRecoveryThreshold {
                    guard let self else { return }
                    Task { [weak self] in await self?.attemptDecodeStallRecovery(decodeIdle: decodeIdle) }
                }

                // Hard trip: decode silent past the teardown threshold.
                // Regardless of reception state - bytes-only-no-decode for
                // 10s is just as broken as silent-everything from the
                // user's point of view.
                guard decodeIdle > StreamSession.frameWatchdogTimeout else { return }
                guard let self else { return }
                Task { [weak self] in
                    guard let self else { return }
                    await self.handleWatchdogTimeout(
                        decodeIdleSeconds: decodeIdle,
                        receiveIdleSeconds: receiveIdle)
                }
            }
            timer.tolerance = 0.1
            self.frameWatchdogTimer = timer
        }
    }

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
                "Present-path stall detected - linkDead=\(trip.linkDead, privacy: .public) tickDeficit=\(trip.tickDeficit, privacy: .public) rendererRejecting=\(trip.rendererRejecting, privacy: .public) rejectStreak=\(live.presentRejectStreak, privacy: .public) sinceTick=\(live.secondsSinceLastTick * 1000, privacy: .public)ms sinceRelease=\(live.secondsSinceLastRelease * 1000, privacy: .public)ms ticks/s=\(live.recentTicksPerSecond, privacy: .public) releases/s=\(live.recentReleasesPerSecond, privacy: .public) depth=\(live.depth, privacy: .public) decodeIdle=\(decodeIdle * 1000, privacy: .public)ms clusterTrips=\(StreamSession.presentTripsInCluster, privacy: .public) - self-healing")
            Diag.info(
                "Present-path stall detected (linkDead=\(trip.linkDead) "
                + "tickDeficit=\(trip.tickDeficit) "
                + "rendererRejecting=\(trip.rendererRejecting) "
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

    /// Log the "bytes received but no decoded output" diagnostic once per
    /// stall episode. Latched so we don't spam the log once a second while
    /// the host continues to send unparseable data.
    fileprivate func handleDecodeOnlyStall(
        decodeIdle: Double, receiveIdle: Double
    ) async {
        guard isStreaming, !stopInProgress, !isReconnecting else { return }
        if didLogDecodeOnlyStall { return }
        didLogDecodeOnlyStall = true
        // .public privacy so this lands in `log show` without --info - the
        // user reproducing "black screen, no error" needs this line.
        log.error(
            // swiftlint:disable:next line_length
            "bytes received but no decoded output: decodeIdle=\(decodeIdle, privacy: .public)s receiveIdle=\(receiveIdle, privacy: .public)s (host is sending data we cannot decode - corrupt bitstream, missing IDR, or codec mismatch)"
        )
        // Mirror into the in-app LogStore so the decode-only stall is visible in
        // Troubleshooting → Logs (which reads only Diag.*).
        Diag.warn(
            "Bytes received but no decoded output: decodeIdle=\(decodeIdle)s "
            + "receiveIdle=\(receiveIdle)s (host is sending data we cannot decode "
            + "- corrupt bitstream, missing IDR, or codec mismatch)",
            "Stream")
    }

    /// Clear the stall latches when decode resumes, so a later stall logs a
    /// fresh diagnostic and re-attempts recovery.
    fileprivate func clearDecodeOnlyStallLatch() async {
        didLogDecodeOnlyStall = false
        didAttemptStallRecovery = false
        didLogWatchdogHold = false
        // Video resumed - drop the hold banner (no-op if it was never shown).
        let winForHide = window
        await MainActor.run { winForHide?.reconnectBanner.setVisible(false) }
    }

    /// Active stall recovery: request an IDR to prompt the host to resume
    /// the video stream after it paused (e.g. the Windows sign-in → desktop
    /// transition stops the encoder briefly). Called each watchdog tick for the
    /// whole stall once past `decodeStallRecoveryThreshold`; the request is
    /// coalesced on the control channel so re-firing per tick is cheap, and we
    /// log once per episode (latched). If the host resumes, decode flows and
    /// `clearDecodeOnlyStallLatch` re-arms us. Teardown is NOT time-bound here:
    /// while the control link is alive the watchdog holds and keeps nudging;
    /// only a genuinely-gone host (ENet dead-peer detection) ends the session.
    fileprivate func attemptDecodeStallRecovery(decodeIdle: Double) async {
        guard isStreaming, !stopInProgress, !isReconnecting else { return }
        backend.requestIdrFrame()
        if didAttemptStallRecovery { return }
        didAttemptStallRecovery = true
        Diag.notice(
            "Video stalled \(String(format: "%.0f", decodeIdle))s - requesting IDR to recover "
            + "(host may have paused video, e.g. the Windows sign-in → desktop transition); "
            + "holding the session while the control link stays alive.",
            "Stream")
    }

    private func handleWatchdogTimeout(
        decodeIdleSeconds: Double, receiveIdleSeconds: Double
    ) async {
        // While a reconnect episode is running the connection is deliberately
        // down (we're rebuilding it under the frozen frame); the episode owns
        // the bounded retry/give-up, so the watchdog must NOT race it to a
        // teardown. It re-arms naturally once frames resume.
        guard isStreaming, !stopInProgress, !isReconnecting else { return }

        // HOLD-IF-ALIVE: a 10s video stall is NOT proof the session is
        // dead. During a Windows sign-in → desktop transition the host pauses
        // the encoder (Sunshine can't capture the secure desktop) while its
        // ENet control loop keeps ACKing our 100ms keepalives - so the link is
        // plainly alive, only video is absent. Tearing down here would kill the
        // session exactly as the user finishes typing their password and the
        // desktop loads. Moonlight rides this out and resumes; so do we. If the
        // control link is unambiguously alive (ACK silence well under ENet's
        // 10s dead-peer timeout), HOLD: the recovery branch keeps requesting
        // IDRs every tick, and we wait for the desktop to return. The genuine
        // "host is gone" teardown is owned by ENet's own dead-peer detection
        // (EnetControlChannel+ControlLoop fires onTerminated(-1) once keepalives
        // stop being ACKed) - a connection-loss signal, not a video-stall one.
        if let health = backend.enetHealth(),
           health.sinceLastAckMs < StreamSession.enetAliveHoldThresholdMs {
            // Hold banner over the frozen frame: "Holding..." since the control
            // link is alive (only video paused) - "Reconnecting..." is reserved
            // for the real reconnect episode. Hidden by clearDecodeOnlyStallLatch.
            let winForHold = window
            await MainActor.run {
                winForHold?.reconnectBanner.setText("Holding...")
                winForHold?.reconnectBanner.setVisible(true)
            }
            if !didLogWatchdogHold {
                didLogWatchdogHold = true
                log.notice(
                    // swiftlint:disable:next line_length
                    "Frame watchdog: no decoded frame in \(decodeIdleSeconds)s but control link is alive (ACK \(health.sinceLastAckMs, privacy: .public)ms ago) - holding, not tearing down (host likely paused video for a sign-in/desktop transition); requesting IDRs until it resumes"
                )
                Diag.notice(
                    "Video stalled \(Int(decodeIdleSeconds))s but the connection is "
                    + "alive - holding and requesting keyframes (host likely paused "
                    + "video for a sign-in / desktop transition). Will reconnect "
                    + "only if the host goes silent.",
                    "Stream")
            }
            return
        }

        let receiveDesc = receiveIdleSeconds.isFinite
            ? "\(receiveIdleSeconds)s"
            : "never"
        log.error(
            // swiftlint:disable:next line_length
            "Frame watchdog tripped - no decoded frame in \(decodeIdleSeconds)s (last byte reception \(receiveDesc, privacy: .public)); tearing down"
        )
        // Also surface to the in-app LogStore (the user's Troubleshooting → Logs
        // view reads ONLY Diag.*, not os.Logger), so a watchdog-triggered stop
        // shows WHY it ran instead of a bare "Stream session stopping".
        Diag.error(
            "Frame watchdog tripped: no decoded frame in \(decodeIdleSeconds)s "
            + "(last byte reception \(receiveDesc)) - tearing down",
            "Stream")
        // P2 DISCONNECT REASON: a watchdog teardown is a decode/present STALL -
        // latch it before the synthetic terminate + stop so the cause is attributed
        // to the stall, not the host-error code the synthetic terminate carries.
        noteTelemetryDisconnect(.watchdogStall)
        // Reuse `connectionTerminated` with a sentinel error code so UI
        // can show a "host became unreachable" message. -1 maps to the
        // existing "Stream ended unexpectedly" handler in MoonlightManager.
        bridge?.eventContinuation?.yield(.connectionTerminated(errorCode: -1))
        await stop()
    }
}

/// Carries per-second-rate baselines for the perceived-hitch pill across the
/// 4Hz overlay ticks. MainActor-isolated: only ever touched from the timer body.
@MainActor
private final class PerceivedHitchBox {
    private var prevStale: UInt64 = 0
    private var prevLate: UInt64 = 0
    private var prevTime: CFTimeInterval = 0
    private var firstTime: CFTimeInterval = 0

    /// Stream seconds before the pill may show. A title's launch (loading +
    /// display-mode negotiation) stutters briefly; without this the pill flashes
    /// the instant a game starts. ~6s covers the launch transient.
    private let graceSeconds: CFTimeInterval = 6.0

    /// True when the PRESENT path is hitching enough to feel. Thresholds sit WELL
    /// above the fps==refresh structural floor (a bookmarked false positive showed
    /// late~6/s, render-gap~0.05, zero real loss) so only a clear burst shows; the
    /// banner's leaky integrator debounces flaps. Deltas guard a reconnect reset.
    func perceivedHitch(snap: StreamStatsSnapshot) -> Bool {
        let now = CACurrentMediaTime()
        if firstTime == 0 { firstTime = now }
        let dt = prevTime > 0 ? now - prevTime : 0.25
        prevTime = now

        // Advance the rate baselines every tick (incl. during the grace) so the
        // first post-grace delta isn't a spurious spike.
        let stale = TelemetryCounters.shared.staleFrameRepeatTotal.value
        let staleRate = (dt > 0 && stale >= prevStale) ? Double(stale - prevStale) / dt : 0
        prevStale = stale
        let late = snap.presentationLateDrops ?? 0
        let lateRate = (dt > 0 && late >= prevLate) ? Double(late - prevLate) / dt : 0
        prevLate = late

        if now - firstTime < graceSeconds { return false }

        var hitch = false
        if let decoded = snap.decodedFps, let rendered = snap.renderedFps, decoded > 0 {
            if (decoded - rendered) / decoded > 0.18 { hitch = true }
        }
        if staleRate > 6.0 { hitch = true }
        if lateRate > 12.0 { hitch = true }
        return hitch
    }
}
