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
    /// Hz deadband below which the floor is treated as already at the requested
    /// rate. The floor is pinned to the FIXED configured fps and held, so a
    /// steady stream never re-pins; this mainly guards the rare panel-max change
    /// (a display switch) from a needless `preferredFrameRateRange` rewrite.
    static let frameRateReapplyHysteresisHz = 8.0

    /// Hold the present-callback floor at the REQUESTED stream refresh - the same
    /// `min(streamHz, panelMax)` that `installLink` pins - re-pinning only if the
    /// panel max changes under us (a display switch that didn't route through
    /// installLink). Called from the main-actor `handleTick`; the steady-state path
    /// is a single pure-math compare (no AppKit read), free on every tick.
    ///
    /// FIDELITY (does NOT track content cadence): the old behavior re-pinned the
    /// floor toward the measured PTS-refined cadence, so wobbly content (Desktop at
    /// ~150fps straddling the 144/165 panel modes) fired a re-pin every dwell
    /// (~0.5/s) - and every `preferredFrameRateRange` write makes the display
    /// renegotiate its refresh rate, which drops a frame (the photographed TestUFO
    /// frameskip gap). The requested refresh is fixed per session, so this re-pins
    /// once (matching install) then early-returns. `preferred`/`maximum` stay at the
    /// panel max - the top end is never given up; only the anti-throttle FLOOR is
    /// held at the requested rate. `refinedIntervalSeconds` is now unused (the due
    /// gate still paces from the raw median, untouched).
    @MainActor
    func reapplyPreferredRangeIfNeeded(refinedIntervalSeconds: Double) {
        guard let link = displayLink, let view = boundView else { return }
        // Item-9 'link installed' replay - one optional load + identity compare
        // per tick in the steady state; see the helper for the WHY.
        replayLinkInstalledBreadcrumbIfNeeded(link: link, view: view)
        let streamHz = configuredFrameIntervalSeconds > 0
            ? 1.0 / configuredFrameIntervalSeconds : 0
        guard streamHz > 0 else { return }
        // Cheap pure-math steady-state exit (no NSScreen read on the hot path):
        // already pinned at the requested refresh. When the request exceeds the
        // panel, appliedFloorHz settles at panelMax and we fall through to the
        // rare NSScreen-read path below, which re-clamps and then no-ops.
        if appliedFloorHz.isFinite,
           abs(streamHz - appliedFloorHz) < Self.frameRateReapplyHysteresisHz {
            return
        }
        let panelMax = Self.panelMaxHz(for: view)
        let targetFloorHz = min(streamHz, panelMax)
        if appliedFloorHz.isFinite,
           abs(targetFloorHz - appliedFloorHz) < Self.frameRateReapplyHysteresisHz {
            return
        }
        let range = Self.preferredRange(
            forStreamIntervalSeconds: configuredFrameIntervalSeconds, panelMaxHz: panelMax)
        link.preferredFrameRateRange = range
        appliedFloorHz = Double(range.minimum)
        // Mirror under the lock for the off-main floor-violation detector
        // (FramePacer+TickDeficit.swift) - same dual-write as installLink.
        os_unfair_lock_lock(&lock)
        pinnedFloorHz = Double(range.minimum)
        os_unfair_lock_unlock(&lock)
        Diag.info(
            "FramePacer pinned present floor to requested \(Double(range.minimum))Hz "
            + "(preferred/max \(Double(range.maximum))Hz, panelMax \(panelMax)Hz; "
            + "content-tracking off for fidelity)",
            "Stream.Pacer")
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
