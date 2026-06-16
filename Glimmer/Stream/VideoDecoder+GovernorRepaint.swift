//
//  VideoDecoder+GovernorRepaint.swift
//
//  The governor-repaint hook for the frame pacer's tick-deficit degraded mode
//  (FramePacer+TickDeficit.swift). Split out of VideoDecoder+API.swift to keep
//  that file under the length limit; this is the single stats-silent enqueue
//  path the pacer's `onDeficitRepaint` drives.
//

import AVFoundation
import CoreMedia
import Foundation

extension VideoDecoder {

    /// GOVERNOR REPAINT (tick-deficit degraded mode): re-enqueue a copy of the
    /// most recently presented frame so the compositor sees a live layer while
    /// CADisplayLink callbacks are collapsed — the suspected lock-in spiral is
    /// "our commits stop → the frame-rate governor classifies the layer static
    /// → holds the throttled rate". Same pixels, so nothing visibly changes.
    ///
    /// Deliberately a SECOND, stats-silent enqueue site beside `presentFrame`
    /// (which is otherwise the single enqueue site): a repaint is NOT a rendered
    /// frame, and routing it through `presentFrame` would inflate fps_rendered /
    /// the present-latency stages during exactly the windows where the degraded
    /// mode's verification contract is renders==received. No drop counting, no
    /// IDR, no FrameTimingTracker stage — invisible to telemetry by design.
    /// Called from the pacer's `onDeficitRepaint` on the pacing queue, already
    /// rate-limited to stream cadence and gated on ≥2 intervals of real-release
    /// silence (FramePacer.maybeRepaintForGovernor).
    nonisolated func repaintFrameForGovernor(_ sampleBuffer: CMSampleBuffer) {
        // Same teardown/readiness gates as presentFrame — a failed or
        // backpressured renderer drops the repaint silently (best-effort:
        // the off-tick release path is the load-bearing failsafe; this only
        // feeds the governor's activity heuristic).
        guard isStreaming, let layer = displayLayer else { return }
        let renderer = layer.sampleBufferRenderer
        guard renderer.status != .failed, renderer.isReadyForMoreMediaData else { return }
        // Copy the sample buffer (shares the pixel buffer — no pixel copy) so
        // the renderer gets a distinct enqueue object rather than the exact
        // instance it already consumed, and mark it display-immediately so its
        // already-shown PTS can't read as stale.
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopy(
            allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer,
            sampleBufferOut: &copy)
        guard status == noErr, let repaint = copy else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(
            repaint, createIfNecessary: true), CFArrayGetCount(attachments) > 0 {
            let entry = unsafeBitCast(
                CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(
                entry,
                Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        renderer.enqueue(repaint)
    }
}
