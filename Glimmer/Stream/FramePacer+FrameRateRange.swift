//
//  FramePacer+FrameRateRange.swift
//
//  The present-callback throttle floor (FIX #1). Split out of FramePacer.swift
//  to keep that file under the length limit; these are the pure / view-reading
//  static helpers that build the CADisplayLink `preferredFrameRateRange` so
//  macOS cannot throttle the present callback below stream cadence on a static
//  layer (the AFK pile-up + 38%-late-drop the pass closes). See `installLink`
//  and `reapplyPreferredRangeIfNeeded` for the callers.
//

import AppKit
import QuartzCore

extension FramePacer {
    /// Hz deadband before the present-callback floor is re-pinned from the
    /// SMOOTHED refined cadence. Widened 5→8 after a wired-link run:
    /// bimodal game content flipped the PTS-median floor 169.81↔175.27Hz
    /// (5.46Hz apart - just past the old 5Hz band) at 12-28 re-pins/s for
    /// ~68k log lines. 8Hz swallows that wobble class outright; a real fps
    /// change (60→120, 240→60) still blows past it within a few ticks.
    static let frameRateReapplyHysteresisHz = 8.0

    /// Per-tick EWMA coefficient for the refined-cadence smoother feeding the
    /// floor re-pin. ~80ms time constant at 240Hz ticks (~170ms at 120):
    /// layered UNDER the deadband, it averages bimodal cadence modes WIDER
    /// than the deadband (game render-rate duty-cycling, e.g. 170↔186) into a
    /// stable midpoint instead of flapping the floor between the extremes,
    /// while a genuine fps change crosses the 8Hz deadband in tens of ms. The
    /// due gate keeps pacing from the RAW median - only the advisory floor is
    /// smoothed, so this can never delay or judder an actual present.
    static let refinedFloorEwmaAlpha = 0.05

    /// Minimum dwell between floor re-pins. Hard-caps `preferredFrameRateRange`
    /// write churn at ≤0.5/s no matter what the estimator does (the same
    /// once-per-MATERIAL-change medicine as the 959a574 screen-rebind gate,
    /// one layer down). A re-pin deferred by the dwell lands when it expires
    /// if the drift persists; a too-low floor in the meantime only permits
    /// static-scene callback throttling for ≤2s (preferred=panelMax still
    /// asks for the full grid), and a too-high floor stays ≤panelMax - both
    /// harmless on any link, jittery or clean.
    static let frameRateRePinMinDwellSeconds = 2.0

    /// Canonical content cadences the Diag mirror rounds to before its dedupe
    /// compare (on a wired-link run the PTS-median cadence legitimately
    /// mode-hopped 66↔92↔144↔240Hz, so the EWMA was mid-transition at almost
    /// every dwell expiry and the raw ≥8Hz compare passed nearly every re-pin -
    /// 3,427 mirror lines = 91.5% of an otherwise 319-line session log).
    /// Rounding collapses the EWMA's transit points onto the mode endpoints,
    /// so the file logs once per CONTENT-MODE change instead of once per
    /// dwell. Advisory-floor telemetry only - pacing never reads this.
    static let contentModesHz: [Double] = [24, 30, 48, 60, 72, 90, 120, 144, 165, 240]

    /// The nearest canonical content mode for a floor value (pass-through for
    /// degenerate input). Pure + nonisolated so it's unit-checkable.
    static func nearestContentModeHz(_ hz: Double) -> Double {
        guard hz.isFinite, hz > 0 else { return hz }
        return contentModesHz.min { abs($0 - hz) < abs($1 - hz) } ?? hz
    }

    /// Re-pin the CADisplayLink's `preferredFrameRateRange` floor (FIX #1) from
    /// the PTS-refined stream cadence when the CLAMPED, SMOOTHED candidate has
    /// drifted past `frameRateReapplyHysteresisHz` from the floor we last
    /// applied. Called from the main-actor `handleTick`; the steady-state path
    /// is pure arithmetic (no AppKit reads), so it stays free on every tick
    /// where cadence is stable.
    ///
    /// RE-PIN STORM FIX (a wired-link run: 97,772 re-pin lines = 78% of
    /// the log - two distinct branches, two medicines):
    ///  1. CLAMP-BEFORE-COMPARE: the old code compared the UNCLAMPED refined
    ///     cadence against `appliedFloorHz`, but applied/stored floors are
    ///     clamped to min(streamHz, panelMax). The PTS median legitimately
    ///     overshoots true content rate on bursty bring-up arrival (read
    ///     247.9-248.6Hz vs fps_received max 241), so whenever refined >
    ///     panelMax + deadband the compare could NEVER settle → a re-pin every
    ///     tick at exactly 240/s (29,132 lines, ~121 cumulative seconds of
    ///     CADisplayLink range writes). Clamping the candidate FIRST makes the
    ///     overshoot benign: 248 clamps to 240, equals the applied floor, done.
    ///  2. EWMA + wider deadband + min-dwell for the bimodal-wobble churn (the
    ///     other ~68k lines) - see the constants above.
    ///
    /// The due-gate cadence base is deliberately NOT touched on a re-pin: a
    /// range write does not make the link's targetTimestamp timebase
    /// discontinuous (the due gate's defensive clamp + starvation failsafe own
    /// real discontinuities), and re-anchoring here would inject a forced
    /// early release per re-pin - a periodic judder source on wobbly cadence.
    @MainActor
    func reapplyPreferredRangeIfNeeded(refinedIntervalSeconds: Double) {
        guard let link = displayLink, let view = boundView else { return }
        // Item-9 'link installed' replay - one optional load + identity compare
        // per tick in the steady state; see the helper for the WHY.
        replayLinkInstalledBreadcrumbIfNeeded(link: link, view: view)
        guard refinedIntervalSeconds.isFinite, refinedIntervalSeconds > 0 else { return }
        let refinedFloorHz = 1.0 / refinedIntervalSeconds
        refinedFloorEwmaHz = refinedFloorEwmaHz.isFinite
            ? refinedFloorEwmaHz
                + Self.refinedFloorEwmaAlpha * (refinedFloorHz - refinedFloorEwmaHz)
            : refinedFloorHz
        // Cheap pure-math pre-check first (no NSScreen read on the hot path):
        // if even the UNCLAMPED smoothed cadence is inside the deadband of the
        // applied floor, the clamped candidate is too (clamping only moves it
        // closer to the applied, panel-clamped value).
        if appliedFloorHz.isFinite,
           abs(refinedFloorEwmaHz - appliedFloorHz) < Self.frameRateReapplyHysteresisHz {
            return
        }
        // CLAMP BEFORE COMPARE - branch 1 of the storm fix (see the doc above).
        let panelMax = Self.panelMaxHz(for: view)
        let candidateFloorHz = min(refinedFloorEwmaHz, panelMax)
        if appliedFloorHz.isFinite,
           abs(candidateFloorHz - appliedFloorHz) < Self.frameRateReapplyHysteresisHz {
            return
        }
        // MIN-DWELL: never re-pin within the dwell of the last re-pin. Checked
        // AFTER the deadband so a deferred drift still lands when the dwell
        // expires; the first-ever application (appliedFloorHz .nan) is exempt.
        let now = CFAbsoluteTimeGetCurrent()
        if appliedFloorHz.isFinite, lastFloorRePinAt.isFinite,
           now - lastFloorRePinAt < Self.frameRateRePinMinDwellSeconds {
            return
        }
        let range = Self.preferredRange(
            forStreamIntervalSeconds: 1.0 / refinedFloorEwmaHz, panelMaxHz: panelMax)
        link.preferredFrameRateRange = range
        appliedFloorHz = Double(range.minimum)
        lastFloorRePinAt = now
        // Mirror under the lock for the off-main floor-violation detector
        // (FramePacer+TickDeficit.swift) - same dual-write as installLink.
        os_unfair_lock_lock(&lock)
        pinnedFloorHz = Double(range.minimum)
        os_unfair_lock_unlock(&lock)
        // DEBUG, not info: every dwell-ceiling re-pin is designed behavior on
        // mode-hopping content (≤0.5/s by the dwell), and at INFO the unified
        // log carried one line per re-pin all session. `log show --debug`
        // still recovers the full record when a re-pin storm needs autopsy.
        log.debug(
            // swiftlint:disable:next line_length
            "FramePacer re-pinned present-callback floor to \(self.appliedFloorHz, privacy: .public)Hz (refined cadence \(refinedFloorHz, privacy: .public)Hz, smoothed \(self.refinedFloorEwmaHz, privacy: .public)Hz)")
        // Diag/LogStore mirror, demoted to ONCE PER CONTENT-MODE CHANGE: the
        // floor is ROUNDED to the nearest canonical mode before the ≥deadband
        // compare (see `contentModesHz` - the raw compare passed nearly every
        // dwell because the EWMA was mid-transition between legitimate modes,
        // 91.5% of one session log). `lastDiagMirroredFloorHz`
        // therefore stores the MODE, not the exact floor; the exact floor
        // rides along in the line for postmortems.
        let mirroredModeHz = Self.nearestContentModeHz(appliedFloorHz)
        if !lastDiagMirroredFloorHz.isFinite
            || abs(mirroredModeHz - lastDiagMirroredFloorHz)
                >= Self.frameRateReapplyHysteresisHz {
            lastDiagMirroredFloorHz = mirroredModeHz
            Diag.info(
                "FramePacer re-pinned present-callback floor to "
                + "\(Double(range.minimum))Hz (mode \(mirroredModeHz)Hz, refined cadence "
                + "\(String(format: "%.2f", refinedFloorHz))Hz)",
                "Stream.Pacer")
        }
    }

    /// One-shot 'link installed' replay into the per-session Diag FILE sink.
    /// The real install breadcrumb (installLink, FramePacer+Recovery.swift)
    /// fires when the stream window first shows - BEFORE StreamSession's
    /// telemetry wiring installs `SessionLogFileSink` - so an affected
    /// session's glimmer-*.log carried ZERO 'link installed' lines and the item-9
    /// verification clause (the floor a session started from) was un-greppable
    /// postmortem. Re-emit the LIVE link's range once per file-sink install
    /// (keyed on the sink instance, so every session replays exactly once and
    /// a telemetry-off session pays one nil load per tick and nothing else).
    @MainActor private static var lastReplayedLogSinkID: ObjectIdentifier?
    @MainActor
    private func replayLinkInstalledBreadcrumbIfNeeded(link: CADisplayLink, view: NSView) {
        guard let sink = SessionLogFileSink.shared else { return }
        let sinkID = ObjectIdentifier(sink)
        guard Self.lastReplayedLogSinkID != sinkID else { return }
        Self.lastReplayedLogSinkID = sinkID
        let range = link.preferredFrameRateRange
        Diag.info(
            "FramePacer link installed - floor=\(Double(range.minimum))Hz "
            + "preferred=\(Double(range.preferred ?? 0))Hz max=\(Double(range.maximum))Hz "
            + "(panelMax=\(Self.panelMaxHz(for: view))Hz) [replayed at session-log start]",
            "Stream.Pacer")
    }

    /// The panel's maximum refresh (Hz) for the screen `view` is currently on.
    /// `NSScreen.maximumFramesPerSecond` is the panel max (120 on ProMotion /
    /// a 4K240 HDR panel at 240, 60 on a stock external). Falls back to 60 when the
    /// view has no window/screen yet (degenerate first bind) so the floor stays
    /// sane. Main-actor: reads NSView/NSScreen.
    @MainActor
    static func panelMaxHz(for view: NSView) -> Double {
        let maxFps = view.window?.screen?.maximumFramesPerSecond
            ?? NSScreen.main?.maximumFramesPerSecond ?? 60
        return maxFps > 0 ? Double(maxFps) : 60.0
    }

    /// Build the CADisplayLink frame-rate range that forbids throttling the
    /// present callback below the stream cadence on a static layer (FIX #1).
    /// `minimum` is pinned to the stream Hz so macOS keeps the callback firing
    /// at stream cadence even on a flat scene; `maximum` is the panel max. The
    /// floor is CLAMPED to `min(streamHz, panelMaxHz)` so a sub-stream-fps
    /// panel never gets an impossible floor. Pure + nonisolated so it's
    /// unit-checkable.
    ///
    /// EXPERIMENT(preferred=panelMax): `preferred` is the PANEL MAX, not the
    /// floor. With preferred==minimum==streamHz (~170 on a 240Hz panel), macOS
    /// quantized the callback grid down to exact panel DIVISORS - sustained
    /// 119.996Hz / 79.997Hz callback seconds on a wired 4K240 session - so the
    /// pacer ran a 170fps stream against a 120Hz-effective grid: standing depth
    /// 3-4 and the o2p p99 tail (~4.8% of frames waited ≥2 vsyncs). Asking for
    /// the full grid (preferred=240) while keeping the anti-throttle floor
    /// (minimum=min(streamHz,panelMax)) costs nothing on the release side - the
    /// due gate already caps at one frame per stream interval, so faster
    /// callbacks only align releases more finely, never release more frames.
    /// JUDGED BY the next wired 240Hz session's realized-tick telemetry
    /// (refresh_min / pacer_ticks_per_s): if the 119.996/79.997Hz callback
    /// seconds vanish, divisor quantization is confirmed; if they persist, the
    /// co-suspect is main-thread tick latency - instrument that next. The same
    /// change doubles as the battery-governor probe (AC vs battery on the
    /// internal panel): a governor that quantizes down from `preferred` may
    /// hold a higher callback rate when preferred reads the panel max.
    static func preferredRange(
        forStreamIntervalSeconds intervalSeconds: Double, panelMaxHz: Double
    ) -> CAFrameRateRange {
        let panel = panelMaxHz.isFinite && panelMaxHz > 0 ? panelMaxHz : 60.0
        let rawStreamHz = intervalSeconds.isFinite && intervalSeconds > 0
            ? 1.0 / intervalSeconds : 60.0
        // Floor never exceeds the panel max (a 60Hz panel can't honor a 120Hz
        // floor); preferred asks for the full panel grid (see EXPERIMENT above).
        let floorHz = min(rawStreamHz, panel)
        let maxHz = max(panel, floorHz)
        return CAFrameRateRange(
            minimum: Float(floorHz), maximum: Float(maxHz), preferred: Float(maxHz))
    }
}
