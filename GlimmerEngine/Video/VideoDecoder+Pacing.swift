// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Share renderer admission across paced presentation, direct fallback and recovery.

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Synchronization
import VideoToolbox
import os

extension VideoDecoder {

    nonisolated var framePacer: FramePacer? {
        get { framePacerBox.withLock { $0.pacer } }
        set {
            let previous = framePacerBox.withLock { route in
                let previous = route.pacer
                let generation = route.generation &+ 1
                newValue?.willPresent = { [weak self] sample in
                    self?.presentFrame(sample, modeGeneration: generation) ?? false
                }
                newValue?.onDeficitRepaint = { [weak self] sample in
                    self?.repaintFrameForGovernor(sample, modeGeneration: generation)
                }
                // Publish invalidation without waiting for an in-flight renderer enqueue on main.
                presentationModeGeneration.store(generation, ordering: .releasing)
                route = PresentationRoute(pacer: newValue, generation: generation)
                return previous
            }
            // Destruction stops the tick thread, which must never run under the route lock.
            withExtendedLifetime(previous) {}
        }
    }

    struct PresentationRoute {
        let pacer: FramePacer?
        let generation: UInt64
    }

    nonisolated func presentationRoute() -> PresentationRoute {
        framePacerBox.withLock { $0 }
    }

    /// Bind after attaching the layer and showing its view on the intended display.
    public func startPacing(display: PacerDisplay, configuredFps: Int32) {
        startPacing(display: display, configuredFps: configuredFps, warmHandover: false)
    }

    // MARK: - Frame pacer bring-up + control surface

    /// Publish a fresh pacer and its admission generation together before starting its link.
    /// Re-engagement preserves direct-style release until healthy display ticks return.
    package func startPacing(
        display: PacerDisplay, configuredFps: Int32, warmHandover: Bool
    ) {
        // Build fresh each session so a restart doesn't inherit stale cadence
        // history or a dead link.
        let pacer = FramePacer(stats: statsCollector, configuredFps: configuredFps)
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
        pacingDisplay = display
        pacer.start(display: display)
    }

    /// Notify the pacer that the stream window changed display (moved to
    /// another monitor) or returned from display sleep, so it rebinds its
    /// CADisplayLink to the new screen's cadence. Called by StreamWindow's
    /// screen-change / wake observers. No-op if pacing isn't up.
    public func pacingScreenDidChange() {
        framePacer?.screenDidChange()
    }

    /// Grow the pacer's adaptive depth one step toward the level EnvSignalController publishes.
    /// Driven by StreamSession's 2 s present-metric timer, the pacer's only grow path. No-op
    /// while pacing is down; `nonisolated` so the timer needs no actor hop.
    package nonisolated func pacingGrowDepthTowardTarget() {
        framePacer?.growDepthTowardTarget()
    }

    // MARK: - Present-path self-heal (watchdog hooks)

    /// Snapshot the pacer's present-side liveness for the present-path
    /// watchdog. Nil if pacing isn't up (the direct-enqueue fallback path,
    /// which can't freeze the way the pacer can). Safe to call from the main
    /// actor - `livenessSnapshot()` is lock-guarded. Module-internal (returns
    /// the pacer's internal `LivenessSnapshot`); the only caller is
    /// StreamSession's present-path watchdog, in the same module.
    package func pacingLiveness() -> FramePacer.LivenessSnapshot? {
        framePacer?.livenessSnapshot()
    }

    /// Escalation step 1 (gate wedged, link still ticking): re-seed the
    /// cadence base so the next tick force-releases. Cheap; preserves pacing.
    package func pacingForceRelease(reason: String) {
        framePacer?.forceReleaseNextTick(reason: reason)
    }

    /// Escalation step 2 (link dead, no ticks): push the freshest queued frame
    /// straight to the renderer so the screen updates while the link rebuilds.
    package func pacingDrainHeadDirectly(reason: String) {
        framePacer?.drainHeadDirectly(reason: reason)
    }

    /// Escalation step 3 (link dead): rebuild the CADisplayLink. Resets the
    /// cadence base, so the first tick after the rebuild releases.
    package func pacingRebuildLink(reason: String) {
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
    package func disablePacingFallbackToDirect(reason: String) {
        guard framePacer != nil else { return }
        // NOTICE, not error: this is a RECOVERABLE transient degradation - the
        // direct path is watched and the adaptive pacer is continuously
        // re-engaged on a healthy link. It is NOT "for the rest of the session".
        log.notice("""
            Present-path paced-recovery did not resume (\(reason, privacy: .public)); transiently reverting to direct renderer \
            enqueue - pacer will re-engage when the link is healthy
            """)
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
    package func reenablePacing(configuredFps: Int32) -> Bool {
        guard framePacer == nil, let display = pacingDisplay else { return false }
        log.notice("""
            Present-path recovered after give-up; re-enabling FramePacer (fresh pacer, warm handover - direct present continues \
            until the rebuilt link proves healthy ticks)
            """)
        Diag.info(
            "Frame pacer re-enabled after present-path recovery (warm handover); "
            + "pacing smoothing restores once the rebuilt link proves healthy ticks",
            "Stream")
        OSSignposter.render.emitEvent("PacerReenabled", "fps=\(configuredFps, privacy: .public)")
        startPacing(display: display, configuredFps: configuredFps, warmHandover: true)
        return true
    }

    /// Flush a stalled renderer and replace a failed layer. A readiness-only stall leaves VT's
    /// reference chain intact, so fresh decoded frames repaint without a host keyframe.
    /// Actual renderer failure and other recovery callers retain keyframe recovery.
    @MainActor
    package func recoverPresentPath(reason: String, requestKeyframe: Bool = true) {
        let layer = displayLayer
        let renderer = layer?.sampleBufferRenderer
        let failed = renderer?.status == .failed
        let needsKeyframe = requestKeyframe || failed
        log.notice("""
            Present-path self-heal (\(reason, privacy: .public)) rendererFailed=\(failed, privacy: .public) - \
            flush\(failed ? "+rebuild" : "") requestKeyframe=\(needsKeyframe, privacy: .public)
            """)
        OSSignposter.render.emitEvent(
            "PresentPathRecover",
            "reason=\(reason, privacy: .public) failed=\(failed, privacy: .public) keyframe=\(needsKeyframe, privacy: .public)")

        // A synchronous return records the call boundary, not completed screen presentation.
        if let renderer {
            recordRendererRecoveryState(renderer: renderer, phase: .flushBegan)
            flushRenderer(renderer)
            recordRendererRecoveryState(renderer: renderer, phase: .flushReturned)
        }

        // 2. If the renderer hard-failed, a flush won't clear it - swap in a
        // fresh layer. The hook re-points us at the new layer + reconfigures
        // colorspace/EDR; if it's unwired (defensive) we keep the flushed layer.
        if failed, let hook = rebuildDisplayLayerHook {
            _ = hook()
        }

        // Readiness recovery can repaint from the next already-decoded image.
        guard needsKeyframe else { return }
        OSSignposter.decode.emitEvent("IDRRequested", "trigger=present_stall")
        backend?.requestIdrFrame()
    }

    /// Coalesces renderer-failure frames into one main-actor recovery.
    /// A failed renderer already drops frames, so deferring one run loop costs
    /// nothing and keeps layer rebuilding on the main actor.
    nonisolated func recoverPresentPathFromRenderQueue(reason: String) -> Bool {
        guard !presentRecoveryPending.exchange(true, ordering: .acquiringAndReleasing) else { return false }
        let generation = attachmentGeneration
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                guard let self else { return }
                guard self.attachmentGeneration == generation else {
                    self.presentRecoveryPending.store(false, ordering: .releasing)
                    return
                }
                self.recoverPresentPath(reason: reason)
                self.presentRecoveryPending.store(false, ordering: .releasing)
            }
        }
        return true
    }

    // The governor-repaint hook (`repaintFrameForGovernor` - the stats-silent
    // re-commit the tick-deficit degraded mode drives) lives in
    // VideoDecoder+GovernorRepaint.swift to keep this file under the length limit.

    struct RendererSubmission {
        let renderer: AVSampleBufferVideoRenderer
        let generation: UInt64
        let modeGeneration: UInt64
    }

    /// The final admission lock orders enqueue against stop, hide, replacement and flush.
    /// Lock order is displayLayerLock then presentSuppressedLock; never call getters inside enqueue.
    nonisolated func rendererSubmission(modeGeneration: UInt64? = nil) -> RendererSubmission? {
        displayLayerLock.lock(); defer { displayLayerLock.unlock() }
        let currentMode = presentationModeGeneration.load(ordering: .acquiring)
        guard isStreaming, !presentSuppressed, let renderer = _sampleBufferRenderer,
              modeGeneration == nil || modeGeneration == currentMode else { return nil }
        return RendererSubmission(renderer: renderer, generation: rendererSubmissionGeneration,
                                  modeGeneration: currentMode)
    }

    nonisolated func performRendererSubmission(
        _ submission: RendererSubmission, enqueue: (AVSampleBufferVideoRenderer) -> Void
    ) -> Bool {
        displayLayerLock.lock(); defer { displayLayerLock.unlock() }
        guard submission.generation == rendererSubmissionGeneration,
              submission.modeGeneration == presentationModeGeneration.load(ordering: .acquiring),
              _sampleBufferRenderer === submission.renderer, isStreaming, !presentSuppressed else { return false }
        enqueue(submission.renderer)
        return true
    }

    /// Invalidate prepared submissions before flushing; new frames may follow the returned call.
    nonisolated func flushRenderer(_ renderer: AVSampleBufferVideoRenderer, keepingDisplayedImage: Bool = false) {
        displayLayerLock.lock(); defer { displayLayerLock.unlock() }
        guard _sampleBufferRenderer === renderer else { return }
        rendererSubmissionGeneration &+= 1
        if keepingDisplayedImage {
            renderer.flush(removingDisplayedImage: false) { }
        } else {
            renderer.flush()
        }
    }

    // MARK: - Paced present site

    /// Release through one renderer admission gate, retaining the route chosen before queue handoff.
    /// A readiness refusal drops this decoded image without invalidating VideoToolbox references.
    @discardableResult
    nonisolated func presentFrame(_ sampleBuffer: CMSampleBuffer, modeGeneration: UInt64? = nil) -> Bool {
        // Re-check the teardown gate: the pacer's serial queue can race a
        // MainActor teardown that nil'd the layer. Snapshot the renderer into
        // a local so it can't be released mid-enqueue.
        guard let submission = rendererSubmission(modeGeneration: modeGeneration) else { return false }
        let renderer = submission.renderer

        // Drive the macOS 15+ renderer from this background queue; the layer API is deprecated.
        // A latched failure stops rendering until flushed, and rebuilding must stay on main.
        if renderer.status == .failed {
            recordRendererDecision(.frameRejectedFailed, sampleBuffer: sampleBuffer)
            // Rebuild a hard-failed renderer because flush cannot clear its
            // latched state; defer AppKit work and repaint from the next IDR.
            let failure = renderer.error as NSError?
            let errorDescription = String(describing: renderer.error)
            if recoverPresentPathFromRenderQueue(reason: "renderer_failed") {
                log.warning(
                    """
                    AVSampleBufferDisplayLayer renderer FAILED; self-healing \
                    (error=\(errorDescription, privacy: .private))
                    """)
                OSSignposter.render.emitEvent(
                    "RendererFailed",
                    """
                    domain=\(failure?.domain ?? "none", privacy: .public) code=\(failure?.code ?? 0, privacy: .public) \
                    error=\(errorDescription, privacy: .private)
                    """)
            }
            return false
        }

        // Bound live-stream latency by dropping decoded images while the renderer isn't ready.
        // Readiness reports OS queue capacity; the present watchdog handles sustained refusal.
        // Dropping a decoded image leaves VT's reference chain intact and does not need an IDR.
        if !renderer.isReadyForMoreMediaData {
            recordRendererDecision(.frameRejectedNotReady, sampleBuffer: sampleBuffer)
            let streak = consecutiveBackpressureDrops.add(1, ordering: .relaxed).newValue
            if streak == 1 {
                recordRendererBackpressureTransition(
                    renderer: renderer, sampleBuffer: sampleBuffer, rejectedFrames: streak, recovered: false)
            }
            statsCollector.recordRendererBackpressureDrop()
            OSSignposter.render.emitEvent(
                "BackpressureDrop",
                "streak=\(streak, privacy: .public)")
            return false
        }

        // A lifecycle rejection must not end an outstanding renderer-backpressure episode.
        // The pacer owns release timing; RTP PTS is not the renderer's Mac host clock.
        // Keep PTS for pacing and telemetry, but display this decoded image when released.
        Self.markForImmediateDisplay(sampleBuffer)
        let tracker = FrameTimingTracker.shared
        guard performRendererSubmission(submission, enqueue: { $0.enqueue(sampleBuffer) }) else { return false }
        let enqueueNanos = tracker?.now()
        let priorRejections = consecutiveBackpressureDrops.exchange(0, ordering: .relaxed)
        sampleHUDBackdrop(sampleBuffer)

        // Capture enqueue before HUD sampling; later diagnostics retain that boundary.
        if let tracker {
            let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
            let rtpTimestamp = VideoDecoder.rtpTimestamp(from: pts)
            tracker.recordPresent(rtpTimestamp: rtpTimestamp, uptimeNanos: enqueueNanos)
            // The last enqueued RTP supplies the video half of the optional AV-skew estimate.
            AudioVideoSkewStore.shared.noteVideoPresented(rtp: rtpTimestamp)
        }

        if priorRejections > 0 {
            recordRendererBackpressureTransition(
                renderer: renderer, sampleBuffer: sampleBuffer, rejectedFrames: priorRejections, recovered: true)
        }

        // Count handoffs to the OS; compositor drops are measured separately.
        statsCollector.recordRendererEnqueue()
        return true
    }

    nonisolated static func markForImmediateDisplay(_ sampleBuffer: CMSampleBuffer) {
        guard let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: true), CFArrayGetCount(attachments) > 0 else { return }
        let entry = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
        CFDictionarySetValue(
            entry,
            Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
            Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
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
