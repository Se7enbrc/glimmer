//
//  StatsCollector+Record.swift
//
//  The hot-path recording API + lightweight accessors for StatsCollector - the
//  per-frame `record*` mutators called from the native backend's receive
//  thread, the VideoToolbox decode queue, and the FramePacer's pacing queue,
//  plus the `secondsSince*` / `*Count` reads the watchdog + telemetry use. Split
//  out of StatsCollector.swift (which keeps the stored state, `reset()`, and the
//  windowed `snapshot()`) so each unit stays under the file-length budget. All
//  methods take the same single `os_unfair_lock` declared on the class; the
//  cross-file extension is intra-module so it shares that internal state.
//

import Foundation
import os

extension StatsCollector {

    func recordReceivedFrame(bytes: Int, isIDR: Bool = false) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        receivedFrames &+= 1
        totalReceived &+= 1
        lastReceivedFrameTime = CFAbsoluteTimeGetCurrent()
        if bytes > 0 {
            receivedBytes &+= UInt64(bytes)
            // Telemetry frame-size + type window accumulators - cheap integer adds
            // under the lock we already hold (no extra hot-path cost).
            windowFrameBytesSum &+= UInt64(bytes)
            windowFrameCount &+= 1
            if bytes > windowMaxFrameBytes { windowMaxFrameBytes = bytes }
            if isIDR { windowIdrFrameCount &+= 1 }
        }
    }

    /// Record that VT produced a CVPixelBuffer for one frame. Distinct from
    /// `recordReceivedFrame` so the StreamSession watchdog can gate on
    /// "did the user see a frame," not "did bytes arrive."
    func recordDecodedFrame() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        lastDecodedFrameTime = CFAbsoluteTimeGetCurrent()
    }

    /// Seconds since the last frame was received from the network, or
    /// `Double.infinity` if we've never received one.
    func secondsSinceLastReceivedFrame() -> Double {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard lastReceivedFrameTime > 0 else { return .infinity }
        return CFAbsoluteTimeGetCurrent() - lastReceivedFrameTime
    }

    /// Seconds since VT successfully decoded a frame, or `Double.infinity`
    /// if we've never decoded one. THIS is what the frame-arrival watchdog
    /// in StreamSession gates on - reception alone doesn't mean the user is
    /// seeing anything.
    func secondsSinceLastDecodedFrame() -> Double {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard lastDecodedFrameTime > 0 else { return .infinity }
        return CFAbsoluteTimeGetCurrent() - lastDecodedFrameTime
    }

    /// Seconds since a frame last reached the renderer (the present clock), or
    /// `Double.infinity` if nothing has presented yet. MODE-AGNOSTIC: fed by the
    /// single `renderer.enqueue` site (`recordRendererEnqueue`) in both the paced
    /// and direct-enqueue paths, so the present-path watchdog gates on real
    /// screen updates in EITHER mode - the detector the direct path was missing.
    func secondsSinceLastPresent() -> Double {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        guard lastPresentTime > 0 else { return .infinity }
        return CFAbsoluteTimeGetCurrent() - lastPresentTime
    }

    /// Record the host-reported `frameHostProcessingLatency` value from one
    /// DECODE_UNIT (Limelight.h: capture + encode time measured *on the
    /// host*, in 1/10 ms units). Zero means the host didn't measure this
    /// frame (e.g. a repeated frame on Sunshine, or GFE which never fills it
    /// in) - we skip the count/sum/min update but still let `max` see the
    /// zero, matching moonlight-qt's exact behavior in ffmpeg.cpp.
    func recordHostProcessingLatency(_ tenthsOfMs: UInt16) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        if tenthsOfMs != 0 {
            if minHostProcessingLatency != 0 {
                minHostProcessingLatency = min(minHostProcessingLatency, tenthsOfMs)
            } else {
                minHostProcessingLatency = tenthsOfMs
            }
            framesWithHostProcessingLatency &+= 1
            totalHostProcessingLatency &+= UInt64(tenthsOfMs)
        }
        maxHostProcessingLatency = max(maxHostProcessingLatency, tenthsOfMs)
    }

    /// Stamp a fresh submit. The caller passes the
    /// `OSSignpostIntervalState` it just got back from
    /// `OSSignposter.beginInterval("DecodeFrame")`; we stash it so the
    /// matching `recordDecodeComplete` / `recordDecodeAbandoned` can return
    /// it for the caller to close the interval - possibly on a different
    /// thread (the VT output callback fires on VT's own queue).
    func recordDecodeSubmit(intervalState: OSSignpostIntervalState) {
        let now = CFAbsoluteTimeGetCurrent()
        var evictedForLeakClose: OSSignpostIntervalState?
        os_unfair_lock_lock(&lock)
        submitFifo.append((timestamp: now, state: intervalState))
        if submitFifo.count > StatsCollector.submitFifoCapacity {
            // Drop the oldest to keep the FIFO bounded. The submit-side opened
            // a "DecodeFrame" interval that a matching `recordDecodeComplete`
            // would normally close - but the matching callback can no longer
            // find this state, so closing the interval is our responsibility.
            // Without the explicit endInterval below the OSSignpostIntervalState
            // token leaks and Instruments draws a dangling DecodeFrame span
            // running forever (visible as a leak in the signpost stream and
            // a permanent open-interval token in the os_signpost subsystem).
            //
            // Hold the evicted state past the unlock and close it outside
            // the unfair-lock critical section: OSSignposter calls are short
            // but we still avoid nesting OS-side calls under our own lock.
            evictedForLeakClose = submitFifo.removeFirst().state
        }
        os_unfair_lock_unlock(&lock)
        if let state = evictedForLeakClose {
            OSSignposter.decode.endInterval(
                "DecodeFrame", state, "outcome=evicted_from_fifo")
        }
    }

    /// Close out a decode submit. Returns the matching
    /// `OSSignpostIntervalState` the caller stamped at submit time so the
    /// caller can close the `DecodeFrame` interval. Returns nil if the FIFO
    /// is empty (stray output callback) - caller should skip the
    /// `endInterval` in that case.
    func recordDecodeComplete(dropped: Bool) -> OSSignpostIntervalState? {
        let now = CFAbsoluteTimeGetCurrent()
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        var poppedState: OSSignpostIntervalState?
        if !submitFifo.isEmpty {
            let head = submitFifo.removeFirst()
            poppedState = head.state
            let elapsed = max(0, now - head.timestamp)
            if let prev = decodeTimeEmaSeconds {
                decodeTimeEmaSeconds = StatsCollector.decodeTimeEmaAlpha * elapsed
                    + (1 - StatsCollector.decodeTimeEmaAlpha) * prev
            } else {
                decodeTimeEmaSeconds = elapsed
            }
        }
        if dropped {
            decoderDroppedFrames &+= 1
            totalDecoderDropped &+= 1
        } else {
            decodedFrames &+= 1
        }
        return poppedState
    }

    /// Abandon a decode submit (e.g. VTDecompressionSessionDecodeFrame
    /// returned non-noErr inline, so the output callback will never fire for
    /// this frame). Returns the matching `OSSignpostIntervalState` so the
    /// caller can close the `DecodeFrame` interval with an "abandoned"
    /// message - leaving it open would have Instruments draw the interval
    /// running forever in the timeline.
    func recordDecodeAbandoned() -> OSSignpostIntervalState? {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        // Pop the most-recent (LIFO) submit - that's the one we just stamped
        // synchronously and which VT rejected inline. We don't credit a
        // "decoded" or "dropped by decoder" frame because VT never saw it.
        var poppedState: OSSignpostIntervalState?
        if !submitFifo.isEmpty {
            poppedState = submitFifo.removeLast().state
        }
        return poppedState
    }

    func recordRendererEnqueue() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        renderedFrames &+= 1
        // Stamp the mode-agnostic present clock here - the single enqueue site
        // for BOTH paced and direct presents - so the present-path watchdog and
        // fps_rendered both source from the actual screen-update moment and
        // never gap on a pacer disable/re-enable transition.
        lastPresentTime = CFAbsoluteTimeGetCurrent()
    }

    /// Record a frame dropped because the AVSampleBufferVideoRenderer was
    /// not ready for more data (its internal queue was full). Per Apple's
    /// AVSampleBufferDisplayLayer docs the correct strategy for real-time
    /// streaming is to drop, not block - see the renderer-backpressure path
    /// in VideoDecoder.enqueueDecodedFrame.
    func recordRendererBackpressureDrop() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        rendererBackpressureDrops &+= 1
    }

    /// Total renderer-backpressure drops since reset(). Used by stream-
    /// session diagnostics; not currently surfaced in the overlay (the
    /// overlay's decoder-dropped row covers the more user-visible drop
    /// path), but logged on teardown for "did we stall a lot" forensics.
    func backpressureDropCount() -> UInt64 {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return rendererBackpressureDrops
    }

    /// Total decoder-side drops since reset() (VT reported
    /// `kVTDecodeInfo_FrameDropped`). The overlay surfaces this as a percentage;
    /// the telemetry exporter wants the absolute count for its drops-by-cause
    /// split. Cheap lock-guarded read, same as `backpressureDropCount`.
    func decoderDropCount() -> UInt64 {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return totalDecoderDropped
    }

    /// Credit a frame DISCARDED in the decode pipeline BEFORE VT produced (or
    /// even saw) an output for it - folded into the decoder-drop cause so the
    /// drops-by-cause split reflects EVERY assembled frame the decode side lost,
    /// not only VT-accepted-then-dropped frames. Three call sites previously
    /// undercounted to ~0%:
    ///   * backlog-overflow `.dropAndFlush` (frame dropped, never dispatched),
    ///   * inline VTDecompressionSessionDecodeFrame rejection (VT never decoded),
    ///   * param-rebuild / no-session early returns (frame dropped pre-VT).
    /// These never reached `recordDecodeComplete(dropped:)`, so a host feeding
    /// undecodable bitstream or a stalled backlog showed ~0 decoder drops. We
    /// increment BOTH the session-cumulative total (the percentage source, over
    /// `totalReceived`) and the window counter so the live FPS-window drop view
    /// also reflects it.
    func recordDecoderDiscard() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        decoderDroppedFrames &+= 1
        totalDecoderDropped &+= 1
    }

    // MARK: - Frame-pacer smoothness

    /// Record a frame the pacer could not present in time - the jitter buffer
    /// overflowed or the adaptive trim aged it out. The NEW third drop cause,
    /// counted separately from decoder + renderer-backpressure drops so the
    /// overlay's drops-by-cause split can attribute "we're behind on
    /// presentation" distinctly from "VT rejected it" / "OS queue full".
    /// Called from FramePacer on the decode queue (submit overflow) and the
    /// pacing queue (vsync trim).
    func recordPresentationLateDrop() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        presentationLateDrops &+= 1
    }

    /// Total presentation-late drops since reset(). Surfaced in the overlay's
    /// drops-by-cause split and logged on teardown.
    func presentationLateDropCount() -> UInt64 {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return presentationLateDrops
    }

    /// Record a PERCEIVED present gap: a drop where the present path showed nothing
    /// fresh (drop-to-newest the renderer also refused) - the felt-stutter signal,
    /// distinct from catch-up discards (which DID present a newer frame).
    func recordPresentationGap() {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        presentationGaps &+= 1
    }

    /// Total perceived present gaps since reset(). Exported as the badge's
    /// felt-stutter telemetry signal.
    func presentationGapCount() -> UInt64 {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        return presentationGaps
    }

    /// Sample the pacing queue depth once per link tick. Updates the live gauge
    /// and the window peak. Called from FramePacer on the pacing queue at the
    /// display's vsync rate (60-240 Hz).
    func recordPacingDepth(_ depth: Int) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        lastPacingDepth = depth
        if depth > maxPacingDepth { maxPacingDepth = depth }
    }

    /// Record one present's cadence error (present-vs-PTS grid delta, ms).
    /// `cadenceErrorMs` may be negative (presented early); we bucket on its
    /// magnitude. Called from FramePacer on the pacing queue once per released
    /// frame.
    func recordPresent(cadenceErrorMs: Double) {
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }
        let magnitude = abs(cadenceErrorMs)
        presentCadenceErrorMsSum += magnitude
        presentCadenceSamples &+= 1
        if magnitude > presentCadenceErrorMsMax { presentCadenceErrorMsMax = magnitude }
        if magnitude <= StatsCollector.presentCadenceToleranceMs {
            onTimePresents &+= 1
        } else {
            latePresents &+= 1
        }
    }
}
