// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Per-frame recording from the receive, decode, and pacing queues.
// Accessors feed the watchdog and telemetry through the collector's lock.

import Foundation
import QuartzCore
import os

extension StatsCollector {

    /// Sunshine's timed captures exclude its repeats when timing is available.
    /// This estimates captured content, not unique game renders; missing timing
    /// falls back to received frames until this connection proves support.
    struct HostFrameRate {
        private struct Sample {
            var duration: Double = 0
            var frames: UInt64 = 0
            var timedFrames: UInt64 = 0
        }

        private var windowStart: CFTimeInterval
        private var frames: UInt64 = 0
        private var timedFrames: UInt64 = 0
        private var hasCaptureTiming = false
        private var value: Double?
        private var samples = [Sample](repeating: Sample(), count: 4)
        private var nextSample = 0

        init(now: CFTimeInterval = CACurrentMediaTime()) {
            windowStart = now
        }

        mutating func record(hostProcessingLatency: UInt16) {
            frames &+= 1
            if hostProcessingLatency > 0 {
                timedFrames &+= 1
                hasCaptureTiming = true
            }
        }

        mutating func sample(now: CFTimeInterval) -> Double? {
            let elapsed = now - windowStart
            // Allow timer jitter around 250 ms without skipping every other tick.
            guard elapsed >= 0.2 else { return value }
            if elapsed >= 1 {
                for index in samples.indices { samples[index] = Sample() }
            }
            samples[nextSample] = Sample(duration: elapsed, frames: frames, timedFrames: timedFrames)
            nextSample = (nextSample + 1) % samples.count
            windowStart = now
            frames = 0
            timedFrames = 0
            let duration = samples.reduce(0) { $0 + $1.duration }
            guard duration >= 1 || samples.allSatisfy({ $0.duration > 0 }) || value != nil else { return nil }
            let count = samples.reduce(UInt64(0)) { $0 + (hasCaptureTiming ? $1.timedFrames : $1.frames) }
            value = Double(count) / duration
            return value
        }
    }

    /// `ptsUs` is the frame's host presentation time (0 = unknown), feeding the
    /// window's host cadence.
    func recordReceivedFrame(bytes: Int, isIDR: Bool = false, ptsUs: UInt64 = 0,
                             frameNumber: Int32, hostProcessingLatency: UInt16 = 0) {
        lock.lock()
        defer { lock.unlock() }
        receivedFrames &+= 1
        totalReceived &+= 1
        hostFrameRate.record(hostProcessingLatency: hostProcessingLatency)
        recordHostProcessingLatencyLocked(hostProcessingLatency)
        let consecutive = lastReceivedFrameNumber.map { frameNumber == $0 &+ 1 } ?? false
        if lastReceivedPtsUs > 0, ptsUs < lastReceivedPtsUs {
            pendingNetworkGapCount = 0
            pendingNetworkGapHead = 0
            lastPresentedPtsSeconds = .nan
            clientSkipSinceLastPresent = true
        }
        if lastReceivedFrameNumber != nil && !consecutive {
            if ptsUs > 0 { enqueueNetworkGapLocked(Double(ptsUs) / 1_000_000.0) }
        }
        foldHostDeltaLocked(ptsUs: ptsUs, consecutive: consecutive)
        lastReceivedFrameNumber = frameNumber
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
        lock.lock()
        defer { lock.unlock() }
        lastDecodedFrameTime = CACurrentMediaTime()
    }

    /// Seconds since VT successfully decoded a frame, or `Double.infinity`
    /// if we've never decoded one. THIS is what the frame-arrival watchdog
    /// in StreamSession gates on - reception alone doesn't mean the user is
    /// seeing anything.
    func secondsSinceLastDecodedFrame() -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard lastDecodedFrameTime > 0 else { return .infinity }
        return CACurrentMediaTime() - lastDecodedFrameTime
    }

    /// Seconds since a frame last reached the renderer (the present clock), or
    /// `Double.infinity` if nothing has presented yet. MODE-AGNOSTIC: fed by the
    /// single `renderer.enqueue` site (`recordRendererEnqueue`) in both the paced
    /// and direct-enqueue paths, so the present-path watchdog gates on real
    /// screen updates in EITHER mode - the detector the direct path was missing.
    func secondsSinceLastPresent() -> Double {
        lock.lock()
        defer { lock.unlock() }
        guard lastPresentTime > 0 else { return .infinity }
        return CACurrentMediaTime() - lastPresentTime
    }

    /// Fold timing with its received frame under the same lock so a snapshot
    /// cannot split their counts. Zero is unmeasured, including Sunshine repeats.
    private func recordHostProcessingLatencyLocked(_ tenthsOfMs: UInt16) {
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
        let now = CACurrentMediaTime()
        var evictedForLeakClose: OSSignpostIntervalState?
        lock.lock()
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
        lock.unlock()
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
        let now = CACurrentMediaTime()
        lock.lock()
        defer { lock.unlock() }
        var poppedState: OSSignpostIntervalState?
        if !submitFifo.isEmpty {
            let head = submitFifo.removeFirst()
            poppedState = head.state
            let elapsed = max(0, now - head.timestamp)
            let split = Self.decodeTimeSplit(
                submit: head.timestamp, callback: now, previousCallback: lastDecodeCallbackTime)
            decodeTimeEmaSeconds = Self.foldDecodeEma(decodeTimeEmaSeconds, elapsed)
            decodeServiceEmaSeconds = Self.foldDecodeEma(decodeServiceEmaSeconds, split.service)
            decodeWaitEmaSeconds = Self.foldDecodeEma(decodeWaitEmaSeconds, split.wait)
        }
        lastDecodeCallbackTime = now
        if dropped {
            decoderDroppedFrames &+= 1
            totalDecoderDropped &+= 1
            clientSkipSinceLastPresent = true
        } else {
            decodedFrames &+= 1
        }
        return poppedState
    }

    /// Split one submit-to-callback span: a frame submitted before the previous
    /// callback queued behind it until then (wait); the rest is VT service time.
    /// Clamped so a stale or out-of-order anchor never yields a negative part.
    static func decodeTimeSplit(submit: CFTimeInterval, callback: CFTimeInterval,
                                previousCallback: CFTimeInterval) -> (service: Double, wait: Double) {
        let end = max(submit, callback)
        let start = min(max(submit, previousCallback), end)
        return (service: end - start, wait: start - submit)
    }

    private static func foldDecodeEma(_ prev: Double?, _ sample: Double) -> Double {
        guard let prev else { return sample }
        return decodeTimeEmaAlpha * sample + (1 - decodeTimeEmaAlpha) * prev
    }

    /// Abandon a decode submit (e.g. VTDecompressionSessionDecodeFrame
    /// returned non-noErr inline, so the output callback will never fire for
    /// this frame). Returns the matching `OSSignpostIntervalState` so the
    /// caller can close the `DecodeFrame` interval with an "abandoned"
    /// message - leaving it open would have Instruments draw the interval
    /// running forever in the timeline.
    func recordDecodeAbandoned() -> OSSignpostIntervalState? {
        lock.lock()
        defer { lock.unlock() }
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
        lock.lock()
        defer { lock.unlock() }
        renderedFrames &+= 1
        // Stamp the mode-agnostic present clock here - the single enqueue site
        // for BOTH paced and direct presents - so the present-path watchdog and
        // fps_rendered both source from the actual screen-update moment and
        // never gap on a pacer disable/re-enable transition.
        let now = CACurrentMediaTime()
        lastPresentTime = now
        // Perceived-gap judge: a drought since the last present with frames
        // still ARRIVING in between means the screen held while content flowed
        // (loss storm / decode starvation / pacing wedge) - a felt gap. Sparse
        // content (nothing arrived) never counts; a designed-idle span
        // (window backgrounded) clears the baseline instead of being judged.
        if gapJudgingExcluded {
            gapBaselineTime = 0
        } else {
            if gapBaselineTime > 0,
               now - gapBaselineTime > Self.perceivedGapSeconds,
               receivedFrames &- gapBaselineReceived >= Self.perceivedGapMinReceived {
                presentationGaps &+= 1
                // Cause split for the exporter: this is the DROUGHT path
                // (content arriving, screen held) - the backoff-reject path
                // increments only the total. Leaf atomic; safe under our lock.
                TelemetryCounters.shared.presentGapDroughtTotal.increment()
            }
            gapBaselineTime = now
            gapBaselineReceived = receivedFrames
        }
    }

    /// Exclude presentation droughts from the perceived-gap judge while the
    /// window is DESIGNED idle (backgrounded/occluded: receive continues,
    /// presents stop). The first present after clearing re-seeds the baseline
    /// un-judged, so the hidden span can never mint a false gap.
    func setGapJudgingExcluded(_ excluded: Bool) {
        lock.lock()
        defer { lock.unlock() }
        gapJudgingExcluded = excluded
        if excluded { gapBaselineTime = 0 }
    }

    /// Record a frame dropped because the AVSampleBufferVideoRenderer was
    /// not ready for more data (its internal queue was full). Per Apple's
    /// AVSampleBufferDisplayLayer docs the correct strategy for real-time
    /// streaming is to drop, not block - see the renderer-backpressure path
    /// in VideoDecoder.enqueueDecodedFrame.
    func recordRendererBackpressureDrop() {
        lock.lock()
        defer { lock.unlock() }
        rendererBackpressureDrops &+= 1
        clientSkipSinceLastPresent = true
    }

    /// Session-total renderer-backpressure drops for stream diagnostics.
    /// The overlay shows decoder drops; teardown logs this separate cause.
    func backpressureDropCount() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return rendererBackpressureDrops
    }

    /// Session-total decoder drops. The overlay uses the percentage;
    /// telemetry needs the absolute count for its drops-by-cause split.
    func decoderDropCount() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
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
        lock.lock()
        defer { lock.unlock() }
        decoderDroppedFrames &+= 1
        totalDecoderDropped &+= 1
        clientSkipSinceLastPresent = true
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
        lock.lock()
        defer { lock.unlock() }
        presentationLateDrops &+= 1
        clientSkipSinceLastPresent = true
    }

    /// Total presentation-late drops this session. Surfaced in the overlay's
    /// drops-by-cause split and logged on teardown.
    func presentationLateDropCount() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return presentationLateDrops
    }

    /// Record a PERCEIVED present gap from the pacer's backoff path: the
    /// drop-to-newest's replacement was ALSO refused, so nothing fresh reached
    /// the screen. The drought-with-content-arriving case is counted inline in
    /// `recordRendererEnqueue` - together they are the felt-stutter signal,
    /// distinct from catch-up discards (which DID present a newer frame).
    func recordPresentationGap() {
        lock.lock()
        defer { lock.unlock() }
        presentationGaps &+= 1
    }

    /// Total perceived present gaps this session. Exported as the badge's
    /// felt-stutter telemetry signal.
    func presentationGapCount() -> UInt64 {
        lock.lock()
        defer { lock.unlock() }
        return presentationGaps
    }

    /// Sample the live pacing queue depth at the display's vsync rate.
    func recordPacingDepth(_ depth: Int) {
        lock.lock()
        defer { lock.unlock() }
        lastPacingDepth = depth
    }

    /// Record one present's cadence error (present-vs-PTS grid delta, ms; bucketed
    /// on magnitude). The frame's host PTS, the stream interval and the refresh
    /// interval let a late present be charged to the host's own timing.
    func recordPresent(cadenceErrorMs: Double, hostPTSSeconds: Double = .nan,
                       streamIntervalMs: Double = 0, refreshMs: Double = 0) {
        lock.lock()
        defer { lock.unlock() }
        let hostDeltaMs = (hostPTSSeconds - lastPresentedPtsSeconds) * 1000.0
        if hostPTSSeconds.isFinite { lastPresentedPtsSeconds = hostPTSSeconds }
        let afterClientSkip = clientSkipSinceLastPresent
        clientSkipSinceLastPresent = false
        var afterNetworkGap = false
        while pendingNetworkGapCount > 0,
              hostPTSSeconds >= pendingNetworkGapPtsSeconds[pendingNetworkGapHead] {
            pendingNetworkGapHead = (pendingNetworkGapHead + 1) % Self.networkGapCapacity
            pendingNetworkGapCount -= 1
            afterNetworkGap = true
        }
        let magnitude = abs(cadenceErrorMs)
        presentCadenceErrorMsSum += magnitude
        presentCadenceSamples &+= 1
        if magnitude > presentCadenceErrorMsMax { presentCadenceErrorMsMax = magnitude }
        if magnitude <= StatsCollector.presentCadenceToleranceMs {
            onTimePresents &+= 1
        } else {
            latePresents &+= 1
            if !afterClientSkip, !afterNetworkGap, Self.hostTimingExplainsLate(
                hostDeltaMs: hostDeltaMs, streamIntervalMs: streamIntervalMs, refreshMs: refreshMs) {
                hostTimedLatePresents &+= 1
            }
        }
    }

    /// Keep the newest gaps when decoding stays hidden longer than the queue.
    /// MUST be called with `lock` held.
    private func enqueueNetworkGapLocked(_ ptsSeconds: Double) {
        let tail = (pendingNetworkGapHead + pendingNetworkGapCount) % Self.networkGapCapacity
        if tail == pendingNetworkGapPtsSeconds.count {
            pendingNetworkGapPtsSeconds.append(ptsSeconds)
        } else {
            pendingNetworkGapPtsSeconds[tail] = ptsSeconds
        }
        if pendingNetworkGapCount == Self.networkGapCapacity {
            pendingNetworkGapHead = (pendingNetworkGapHead + 1) % Self.networkGapCapacity
        } else {
            pendingNetworkGapCount += 1
        }
    }

    /// Whether the host's timing alone makes a present late: even the best present
    /// it allowed (its frame delta, but no sooner than one refresh) misses the
    /// stream interval by more than the cadence tolerance.
    static func hostTimingExplainsLate(hostDeltaMs: Double, streamIntervalMs: Double,
                                       refreshMs: Double) -> Bool {
        guard hostDeltaMs > 0, hostDeltaMs < 1_000, streamIntervalMs > 0 else { return false }
        return abs(max(hostDeltaMs, refreshMs) - streamIntervalMs) > presentCadenceToleranceMs
    }

    /// Fold one received frame's host PTS into the window's host cadence. Zero, a
    /// backward step, frame skip or a gap of 1 s or more breaks the chain.
    /// MUST be called with `lock` held.
    func foldHostDeltaLocked(ptsUs: UInt64, consecutive: Bool) {
        defer { lastReceivedPtsUs = ptsUs }
        guard consecutive, lastReceivedPtsUs > 0, ptsUs > lastReceivedPtsUs,
              ptsUs - lastReceivedPtsUs < 1_000_000 else {
            lastHostDeltaMs = 0
            return
        }
        let deltaMs = Double(ptsUs - lastReceivedPtsUs) / 1000.0
        if windowHostDeltasMs.count < Self.hostDeltaWindowCap { windowHostDeltasMs.append(deltaMs) }
        if lastHostDeltaMs > 0,
           max(deltaMs, lastHostDeltaMs) >= Self.hostUnevenRatio * min(deltaMs, lastHostDeltaMs) {
            windowHostUnevenPairs &+= 1
        }
        lastHostDeltaMs = deltaMs
    }
}
