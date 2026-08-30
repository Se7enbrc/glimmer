//
//  VideoDecoder+Pacing.swift
//
//  The display-clock frame pacer's wiring and the whole present path: pacer
//  bring-up (`startPacing`) plus its control surface, the single paced present
//  site (`presentFrame` - the renderer-status and backpressure policy around the
//  one `renderer.enqueue` call), and the mode-agnostic present-path self-heal the
//  watchdog escalates through. Split out of VideoDecoder+API.swift and
//  VideoDecoder+Session.swift to keep each unit focused; see VideoDecoder.swift
//  for the decoder's stored state.
//

import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import VideoToolbox
import os

extension VideoDecoder {

    // MARK: - Frame pacer bring-up + control surface

    /// Stand up the display-clock frame pacer and bind its CADisplayLink to
    /// `view`'s screen. Called by StreamSession on the main actor right after
    /// `StreamWindow.show()` puts the window on a display, so the link is bound
    /// to the screen the stream actually lives on. `configuredFps` seeds the
    /// pacer's cadence estimate (it self-corrects from host PTS deltas within
    /// ~1s, but seeding avoids a startup beat of wrong cadence).
    ///
    /// The pacer's `willPresent` hook routes to `presentFrame(_:)` (renderer-
    /// status + backpressure policy + the single `renderer.enqueue` site), which
    /// fires on the pacer's dedicated serial queue, never the main actor. The
    /// pacer no longer has a sustained-lag → IDR hook: a presentation-timing trim
    /// of an already-decoded frame never requests a keyframe (the reference chain
    /// is intact), so that escalation path is gone entirely.
    public func startPacing(
        drivingView view: NSView, configuredFps: Int32, warmHandover: Bool = false
    ) {
        // Build fresh each session so a restart doesn't inherit stale cadence
        // history or a dead link.
        let pacer = FramePacer(stats: statsCollector, configuredFps: configuredFps)
        pacer.willPresent = { [weak self] sampleBuffer in
            guard let self else { return false }
            return self.presentFrame(sampleBuffer)
        }
        // Governor-repaint hook (tick-deficit degraded mode): re-commits the
        // current frame WITHOUT counting a rendered frame - deliberately NOT
        // routed through presentFrame, whose stats would fake renders>received
        // during a deficit. See `repaintFrameForGovernor` for the enqueue-site
        // rationale.
        pacer.onDeficitRepaint = { [weak self] sampleBuffer in
            self?.repaintFrameForGovernor(sampleBuffer)
        }
        // A rebuilt pacer must inherit the decoder's CURRENT suppression state:
        // the pacer-side flag mirrors VideoDecoder's (which outlives a pacer
        // rebuild - see the field doc in FramePacer.swift), but a fresh pacer's
        // copy starts false, so one stood up while the window is hidden would
        // mint ~120/s of fake overflow late-drops until the next suppression
        // edge re-stamps it. Stamp BEFORE publishing the pacer so a submit
        // racing the rebuild already takes the suppressed branch. This is the
        // single construction site (reenablePacing routes through here).
        pacer.setPresentSuppressed(presentSuppressed)
        // WARM HANDOVER (re-enable path only): keep direct-presenting until the
        // rebuilt link proves healthy ticks, then cut over atomically - the
        // cold cutover re-froze the stream 350ms after a measured re-enable.
        // Armed BEFORE publishing the pacer so the first submit already takes
        // the warm path. A cold SESSION start stays queued-from-frame-1: its
        // link has no failure history, the watchdog grace covers priming, and
        // the fade-in hides the first beats - no reason to change a path the
        // wired 4K240 baseline validates.
        if warmHandover {
            pacer.armWarmHandover()
        }
        framePacer = pacer
        // Remember the driving view so the present-watchdog's give-up → re-enable
        // path can rebuild onto the same screen without touching the actor-
        // isolated StreamWindow.
        pacingDrivingView = view
        pacer.start(drivingView: view)
    }

    /// Notify the pacer that the stream window changed display (moved to
    /// another monitor) or returned from display sleep, so it rebinds its
    /// CADisplayLink to the new screen's cadence. Called by StreamWindow's
    /// screen-change / wake observers. No-op if pacing isn't up.
    public func pacingScreenDidChange() {
        framePacer?.screenDidChange()
    }

    /// Forward the latest SMOOTHED RFC-3550 reorder jitter (ms) to the pacer so it
    /// grows the adaptive buffer only for SUSTAINED MEASURED jitter (the lossy
    /// wifi case) and rests at depth 1 on a clean link. Driven on the present-
    /// metric timer's ~2s cadence (StreamSession), matching the cadence on which
    /// `TelemetryCounters.recvJitterMs` is refreshed by the RTP receive path. The
    /// pacer ALSO reads the shared gauge on its own tick path, so this is the
    /// explicit, cadence-aligned grow signal rather than the sole one. No-op if
    /// pacing isn't up. `nonisolated` so the metric timer can call without an
    /// actor hop; `livenessSnapshot()`/`noteMeasuredJitter` are lock-guarded.
    nonisolated func pacingNoteMeasuredJitter(_ ms: Double) {
        framePacer?.noteMeasuredJitter(ms)
    }

    // MARK: - Present-path self-heal (watchdog hooks)

    /// Snapshot the pacer's present-side liveness for the present-path
    /// watchdog. Nil if pacing isn't up (the direct-enqueue fallback path,
    /// which can't freeze the way the pacer can). Safe to call from the main
    /// actor - `livenessSnapshot()` is lock-guarded. Module-internal (returns
    /// the pacer's internal `LivenessSnapshot`); the only caller is
    /// StreamSession's present-path watchdog, in the same module.
    func pacingLiveness() -> FramePacer.LivenessSnapshot? {
        framePacer?.livenessSnapshot()
    }

    /// Escalation step 1 (gate wedged, link still ticking): re-seed the
    /// cadence base so the next tick force-releases. Cheap; preserves pacing.
    func pacingForceRelease(reason: String) {
        framePacer?.forceReleaseNextTick(reason: reason)
    }

    /// Escalation step 2 (link dead, no ticks): push the freshest queued frame
    /// straight to the renderer so the screen updates while the link rebuilds.
    func pacingDrainHeadDirectly(reason: String) {
        framePacer?.drainHeadDirectly(reason: reason)
    }

    /// Escalation step 3 (link dead): rebuild the CADisplayLink. Resets the
    /// cadence base, so the first tick after the rebuild releases.
    func pacingRebuildLink(reason: String) {
        framePacer?.rebuildLink(reason: reason)
    }

    /// Graceful TRANSIENT degradation: tear the pacer down and revert to DIRECT
    /// renderer enqueue while the present path is rough. We lose the jitter-buffer
    /// smoothing temporarily, but the direct path is WATCHED - the present-path
    /// watchdog gates on the mode-agnostic present clock and self-heals a direct
    /// wedge (flush / layer-rebuild / IDR), and the adaptive pacer is continuously
    /// re-engaged once the link is healthy. `enqueueDecodedFrame` falls through to
    /// `presentFrame` when `framePacer` is nil (the same fallback the early-frame
    /// path uses). This is NEVER a permanent one-way disable.
    func disablePacingFallbackToDirect(reason: String) {
        guard framePacer != nil else { return }
        // NOTICE, not error: this is a RECOVERABLE transient degradation - the
        // direct path is watched and the adaptive pacer is continuously
        // re-engaged on a healthy link. It is NOT "for the rest of the session".
        // swiftlint:disable:next line_length
        log.notice("Present-path paced-recovery did not resume (\(reason, privacy: .public)); transiently reverting to direct renderer enqueue - pacer will re-engage when the link is healthy")
        Diag.info(
            "Frame pacer transiently disabled after present-path stall (\(reason)); "
            + "stream continues with direct presentation, pacing re-engages when healthy",
            "Stream")
        OSSignposter.render.emitEvent("PacerDisabled", "reason=\(reason, privacy: .public)")
        TelemetryCounters.shared.pacerDisabledTotal.increment()
        framePacer?.stop()
        framePacer = nil
    }

    /// Re-enable pacing after a stage-3 give-up dropped us to direct enqueue,
    /// once the present path has been healthy long enough that the give-up was a
    /// transient drought (a VPN-delayed IDR) rather than a wedged pipeline. A
    /// FRESH `FramePacer` is built (the same clean-state path `startPacing` uses
    /// at session start), so the restore can't inherit the cadence/link
    /// discontinuity that tripped the give-up. No-op if a pacer somehow already
    /// exists (defensive - the give-up nil'd it) or the driving view is gone
    /// (window torn down - nothing to pace onto). Returns true if pacing was
    /// rebuilt. Driven by StreamSession's present-path watchdog, which owns the
    /// stability-window timing and the per-session give-up budget.
    func reenablePacing(configuredFps: Int32) -> Bool {
        guard framePacer == nil, let view = pacingDrivingView else { return false }
        log.notice(
            // swiftlint:disable:next line_length
            "Present-path recovered after give-up; re-enabling FramePacer (fresh pacer, warm handover - direct present continues until the rebuilt link proves healthy ticks)")
        Diag.info(
            "Frame pacer re-enabled after present-path recovery (warm handover); "
            + "pacing smoothing restores once the rebuilt link proves healthy ticks",
            "Stream")
        OSSignposter.render.emitEvent("PacerReenabled", "fps=\(configuredFps, privacy: .public)")
        startPacing(drivingView: view, configuredFps: configuredFps, warmHandover: true)
        return true
    }

    /// MODE-AGNOSTIC present-path recovery. The single self-heal routine for a
    /// genuine present freeze (decode healthy, nothing reaching the screen),
    /// called from BOTH the pacer-stall path and the new direct-path stall - so
    /// the direct enqueue path is no longer unwatched after a give-up.
    ///
    /// Escalation, cheapest first:
    ///   1. Flush the renderer (clears a soft-stuck queue / requiresFlush latch).
    ///   2. If the renderer has HARD-latched `.status == .failed` - a 4K240 HDR panel
    ///      4K240 HDR wedge, which a bare flush does NOT always clear - rebuild
    ///      the AVSampleBufferDisplayLayer entirely via the wired hook (fresh
    ///      layer, re-attached overlay, re-applied colorspace) so the failed
    ///      renderer is replaced rather than uselessly re-flushed forever.
    ///   3. Request a fresh IDR so the (flushed or rebuilt) renderer repaints
    ///      from a clean keyframe.
    ///
    /// Generalizes the old `requestIdrForPresentStall` and the inline
    /// renderer-FAILED block in `presentFrame` into one place. MainActor -
    /// rebuilding the layer touches AppKit. `nonisolated`-callable wrappers exist
    /// for the pacer/decode-queue FAILED path; see `recoverPresentPathFromRenderQueue`.
    @MainActor
    func recoverPresentPath(reason: String) {
        let layer = displayLayer
        let renderer = layer?.sampleBufferRenderer
        let failed = renderer?.status == .failed
        log.notice(
            // swiftlint:disable:next line_length
            "Present-path self-heal (\(reason, privacy: .public)) rendererFailed=\(failed, privacy: .public) - flush\(failed ? "+rebuild" : "")+IDR")
        OSSignposter.render.emitEvent(
            "PresentPathRecover",
            "reason=\(reason, privacy: .public) failed=\(failed, privacy: .public)")

        // 1. Flush whatever renderer we currently have.
        renderer?.flush()

        // 2. If the renderer hard-failed, a flush won't clear it - swap in a
        // fresh layer. The hook re-points us at the new layer + reconfigures
        // colorspace/EDR; if it's unwired (defensive) we keep the flushed layer.
        if failed, let hook = rebuildDisplayLayerHook {
            _ = hook()
        }

        // 3. Repaint from a clean keyframe on the live (flushed or rebuilt) path.
        OSSignposter.decode.emitEvent("IDRRequested", "trigger=present_stall")
        backend?.requestIdrFrame()
    }

    /// Renderer-FAILED recovery reachable from the pacer/decode queue (NOT the
    /// main actor) - the inline `presentFrame` failed-status branch. Hops to the
    /// main actor to run the full `recoverPresentPath` (which may rebuild the
    /// layer). The hop is fine: a failed renderer is already dropping frames, so
    /// the one-runloop deferral to rebuild costs nothing and avoids touching
    /// AppKit off the main actor.
    nonisolated func recoverPresentPathFromRenderQueue(reason: String) {
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated { self?.recoverPresentPath(reason: reason) }
        }
    }

    // The governor-repaint hook (`repaintFrameForGovernor` - the stats-silent
    // re-commit the tick-deficit degraded mode drives) lives in
    // VideoDecoder+GovernorRepaint.swift to keep this file under the length limit.

    // MARK: - Paced present site

    /// Present one paced frame onto the AVSampleBufferDisplayLayer's renderer.
    /// Invoked by `FramePacer` via its `willPresent` hook on the pacer's
    /// dedicated serial queue (NOT the main actor) at the moment a frame is due
    /// for its vsync - or inline from `enqueueDecodedFrame` on the fallback
    /// path when the pacer isn't running. Returns true if the frame was handed
    /// to the renderer, false if it was dropped (renderer failed / not ready).
    ///
    /// This owns the renderer-status + backpressure policy that used to live
    /// inline in the VT callback:
    ///   * renderer.status == .failed → flush + request an IDR (unchanged).
    ///   * renderer not ready for more media → drop + count (no IDR here; a
    ///     presentation-timing drop of an already-decoded frame never requests a
    ///     keyframe - the reference chain is intact).
    @discardableResult
    nonisolated func presentFrame(_ sampleBuffer: CMSampleBuffer) -> Bool {
        // Re-check the teardown gate: the pacer's serial queue can race a
        // MainActor teardown that nil'd the layer. Snapshot the layer into a
        // local so it can't be released mid-enqueue.
        guard isStreaming, let layer = displayLayer else { return false }

        // ---- Renderer via the macOS 15+ AVSampleBufferVideoRenderer path.
        //
        // On macOS 15+, calling `enqueueSampleBuffer:` (and the matching
        // flush/status/error) directly on the AVSampleBufferDisplayLayer
        // is deprecated. The replacement is `layer.sampleBufferRenderer`
        // (AVSampleBufferVideoRenderer), which is explicitly safe to drive
        // from a background thread - exactly the pacer's serial queue here.
        //
        // If the renderer's status latched to `.failed` (bad sample, an HDR
        // mid-stream toggle, or other decoder glitch), it silently stops
        // rendering further enqueued samples until we call `flush()`.
        // moonlight-qt handles the equivalent on older macOS by pushing
        // SDL_RENDER_DEVICE_RESET and recreating the decoder. We do it
        // cheaper: flush + request an IDR via the backend, and let VT pick
        // up where it left off.
        let renderer = layer.sampleBufferRenderer
        if renderer.status == .failed {
            log.warning(
                "AVSampleBufferDisplayLayer renderer FAILED; self-healing (error=\(String(describing: renderer.error)))")
            // Surface the "I lost a frame to the OS" moment as a discrete
            // event so a profile run can spot the recovery amongst the
            // per-frame intervals.
            OSSignposter.render.emitEvent(
                "RendererFailed",
                "error=\(String(describing: renderer.error), privacy: .public)")
            // Route to the MODE-AGNOSTIC self-heal: flush, and if the renderer
            // has HARD-failed (a bare flush won't clear it - the 4K240
            // HDR wedge), REBUILD the layer so the present path can't latch
            // failed forever (the old behaviour: flush-noop → IDR → return false
            // every frame, decode healthy, screen frozen, no escalation). The
            // recovery hops to the main actor to touch AppKit; we drop THIS
            // frame and the next keyframe lands on the recovered layer.
            recoverPresentPathFromRenderQueue(reason: "renderer_failed")
            return false
        }

        // ---- Renderer backpressure (Apple docs explicitly recommend dropping
        // for live content). When AVSampleBufferVideoRenderer's internal queue
        // fills, `isReadyForMoreMediaData` flips to false. The pacer already
        // bounds our own wall-clock latency upstream, so a not-ready renderer
        // here is the OS-side queue momentarily full - we drop this frame and
        // count it, but DON'T request an IDR off it: a single late vsync can
        // flip the flag for one frame, and an IDR on transient jitter just
        // compounds lag. A presentation-timing drop of an already-decoded frame
        // never requests a keyframe - the reference chain is intact.
        if !renderer.isReadyForMoreMediaData {
            consecutiveBackpressureDrops += 1
            statsCollector.recordRendererBackpressureDrop()
            OSSignposter.render.emitEvent(
                "BackpressureDrop",
                "streak=\(self.consecutiveBackpressureDrops, privacy: .public)")
            return false
        }

        // Healthy frame - reset the backpressure streak and present.
        consecutiveBackpressureDrops = 0
        renderer.enqueue(sampleBuffer)

        // Latency telemetry stage t_present (opt-in; nil = zero cost): the frame
        // just reached the renderer. Recover the rtpTimestamp key from the sample
        // buffer's PTS, look up the in-flight entry, compute the five deltas, feed
        // the histograms + per-frame trace, and evict. This is the only stage that
        // mutates the histograms / appends a trace line, all off the proven path.
        if let tracker = FrameTimingTracker.shared {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let rtpTimestamp = VideoDecoder.rtpTimestamp(from: pts)
            tracker.recordPresent(rtpTimestamp: rtpTimestamp)
            // AV-skew VIDEO half (`av_skew_ms`): the host-timeline RTP of the
            // frame that just reached the renderer - the one-word store the
            // deferred cross-stream derivation needed. Inside the tracker
            // nil-check so telemetry-off sessions stay zero-cost.
            AudioVideoSkewStore.shared.noteVideoPresented(rtp: rtpTimestamp)
        }

        // Stats: one renderer enqueue equals one frame handed to the OS for
        // v-sync presentation. The OS may still drop it at composite time if
        // it falls behind, but that's outside our visibility - moonlight-qt's
        // "rendering FPS" row is defined the same way.
        statsCollector.recordRendererEnqueue()
        return true
    }

    // A presentation-late / drop-to-newest / sustained-lag drop in the
    // FramePacer discards an ALREADY-DECODED CMSampleBuffer from the present
    // queue - the VideoToolbox decoder already decoded it, so the reference
    // chain is INTACT and NO IDR is needed. Requesting a keyframe for a
    // presentation-timing drop is a category error: it can't fix pacing, and at
    // 4K240 the bitrate-capped IDR arrives soft/blocky then refines = a
    // visible blur/refocus. The old `notePacerSustainedLag` IDR-after-N
    // trigger (and the pacer's `onSustainedLag` signal that fed it) is therefore
    // GONE - the pacer keeps trimming-to-newest and keeps counting
    // presentation-late drops (that telemetry is correct + load-bearing), but
    // never escalates a pacing trim to a keyframe. IDR/RFI is now reserved for
    // GENUINE decode/reference breaks only: real packet loss (the depacketizer
    // RFI state machine) or a VT decode error.
}
