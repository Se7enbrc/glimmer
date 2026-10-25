// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Repaint the last frame when display callbacks collapse, without counting a new video frame.

import AVFoundation
import CoreMedia
import Foundation

extension VideoDecoder {

    /// Re-submit the same pixels to keep the compositor active when display ticks collapse.
    /// The pacer limits repeats to stream cadence after two silent intervals. Separate trace
    /// events preserve visibility without inflating rendered FPS, drops or latency histograms.
    nonisolated func repaintFrameForGovernor(_ sampleBuffer: CMSampleBuffer, modeGeneration: UInt64? = nil) {
        // Best effort: the off-tick release path remains responsible for delivering new frames.
        guard let submission = rendererSubmission(modeGeneration: modeGeneration) else { return }
        let renderer = submission.renderer
        guard renderer.status != .failed else {
            recordRendererDecision(.repaintRejectedFailed, sampleBuffer: sampleBuffer)
            return
        }
        guard renderer.isReadyForMoreMediaData else {
            recordRendererDecision(.repaintRejectedNotReady, sampleBuffer: sampleBuffer)
            return
        }
        // Share the pixels but give the renderer a distinct object. Display-immediately prevents
        // the already-shown PTS from being treated as stale.
        var copy: CMSampleBuffer?
        let status = CMSampleBufferCreateCopy(
            allocator: kCFAllocatorDefault, sampleBuffer: sampleBuffer,
            sampleBufferOut: &copy)
        guard status == noErr, let repaint = copy else {
            recordRendererDecision(.repaintCopyFailed, sampleBuffer: sampleBuffer)
            return
        }
        Self.markForImmediateDisplay(repaint)
        guard performRendererSubmission(submission, sampleBuffer: repaint, repainting: true,
                                        enqueue: { $0.enqueue(repaint) }) else { return }
        recordRendererDecision(.repaintEnqueued, sampleBuffer: sampleBuffer)
    }

    /// The existing bounded frame writer owns I/O; telemetry-off never extracts frame identity.
    nonisolated func recordRendererDecision(
        _ decision: FrameInstrumentation.RendererDecision, sampleBuffer: CMSampleBuffer
    ) {
        #if os(macOS) || GLIMMER_DIAGNOSTICS
        guard let tracker = FrameInstrumentation.shared else { return }
        let pts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        tracker.recordRendererDecision(decision, rtpTimestamp: Self.rtpTimestamp(from: pts))
        #endif
    }

    /// Only the first refusal and next accepted frame read these additional framework properties.
    nonisolated func recordRendererBackpressureTransition(
        renderer: AVSampleBufferVideoRenderer, sampleBuffer: CMSampleBuffer,
        rejectedFrames: Int, recovered: Bool
    ) {
        #if os(macOS) || GLIMMER_DIAGNOSTICS
        guard let tracker = FrameInstrumentation.shared else { return }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(
            sampleBuffer, createIfNecessary: false) as? [[String: Any]]
        let immediate = attachments?.first?[kCMSampleAttachmentKey_DisplayImmediately as String] as? Bool ?? false
        tracker.recordRendererState(.init(
            phase: recovered ? .backpressureEnded : .backpressureBegan,
            status: renderer.status.rawValue, ready: recovered,
            requiresFlush: renderer.requiresFlushToResumeDecoding,
            generation: attachmentGeneration(for: renderer), rejectedFrames: rejectedFrames,
            pts: CMSampleBufferGetPresentationTimeStamp(sampleBuffer), displayImmediately: immediate))
        #endif
    }

    /// Capture the observed state around a flush call without asserting asynchronous completion.
    nonisolated func recordRendererRecoveryState(
        renderer: AVSampleBufferVideoRenderer, phase: FrameInstrumentation.RendererStatePhase
    ) {
        #if os(macOS) || GLIMMER_DIAGNOSTICS
        guard let tracker = FrameInstrumentation.shared else { return }
        tracker.recordRendererState(.init(
            phase: phase, status: renderer.status.rawValue, ready: renderer.isReadyForMoreMediaData,
            requiresFlush: renderer.requiresFlushToResumeDecoding,
            generation: attachmentGeneration(for: renderer)))
        #endif
    }
}
