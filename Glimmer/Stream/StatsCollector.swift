//
//  StatsCollector.swift
//
//  Thread-safe counters for the in-stream stats overlay. Owned by
//  `VideoDecoder` for the lifetime of one streaming session.
//
//  Touched from three thread contexts during normal operation:
//    * The native backend's receive thread, via `recordReceivedFrame` - once
//      per submitDecodeUnit, before VT touches anything.
//    * VT decode dispatch queue, via `recordDecodeSubmit` /
//      `recordDecodeComplete` / `recordDecodeAbandoned` /
//      `recordRendererEnqueue`. Submit and complete fire in lock-step on the
//      same queue (we serialize decode on a single queue with ThreadCount=1),
//      so the submit-time FIFO doesn't need an external lock for ordering -
//      just for the cross-thread snapshot read.
//    * The FramePacer's dedicated serial queue, via `recordPacingDepth` (once
//      per display vsync, 60-240 Hz) / `recordPresent` (once per released
//      frame) / `recordPresentationLateDrop` (on overflow + trim). The same
//      lock serializes these against the snapshot read.
//    * Main actor, via `snapshot(minWindowSeconds:)` / `reset()` - at 4 Hz
//      from the overlay timer. The FPS averaging window is DECOUPLED from that
//      tick: `snapshot(minWindowSeconds:)` only slides + recomputes the
//      window-relative fields once `minWindowSeconds` (~1s) of data has
//      accumulated, serving the cached last-good average on the in-between
//      ticks (see the cache block + the window-complete gate in snapshot()).
//      A literal 500ms window was too tight at 60Hz - single-frame boundary
//      effects pushed the displayed FPS by ±2fps; the ~1s window smooths to
//      ±1fps on a steady stream while the live latency gauges still refresh
//      every 4 Hz tick. The telemetry exporter calls it with the default
//      `minWindowSeconds == 0`, preserving the original reset-every-read
//      window on its own cadence.
//
//  All shared mutable state is protected by a single os_unfair_lock. The hot
//  paths only hold it for a handful of integer/double updates per frame -
//  well under a microsecond - which at 240 FPS is nowhere near a contention
//  risk and orders of magnitude under any frame-pacing budget. Using a lock
//  rather than atomics here is the right tradeoff: the decode-time EMA and
//  submit FIFO need consistent multi-field updates, and a single lock is
//  simpler than juggling several `OSAtomic*` calls.

import Foundation
import os
final class StatsCollector: @unchecked Sendable {

    /// FIFO of `(timestamp, intervalState)` pairs for in-flight decode
    /// submits. Timestamps come from `CFAbsoluteTimeGetCurrent()` - wall-
    /// clock seconds, ms resolution. Bounded at 64 entries which is well
    /// over the deepest in-flight queue VT hands us at 4K/240 (typically
    /// 1-2, occasionally 4 during a P-frame burst); overflow drops the
    /// oldest, biasing the EMA slightly toward recent frames - acceptable
    /// for a diagnostic readout.
    ///
    /// The `OSSignpostIntervalState` is `Sendable` (macOS 13+) so we hand
    /// it back to `OSSignposter.endInterval` from the VT output callback,
    /// even though `beginInterval` ran on a different thread. The flat
    /// `removeFirst` pop is O(N) but N ≤ 64, well under a microsecond.
    var submitFifo: [(timestamp: CFAbsoluteTime, state: OSSignpostIntervalState)] = []
    static let submitFifoCapacity = 64

    /// EMA of decoder wall-clock time, in seconds. `nil` until the first
    /// completed frame, then updated via `avg = alpha * sample + (1-alpha) * avg`.
    /// alpha = 0.1 → roughly the last ~10 frames dominate the average, which
    /// matches moonlight-qt's `m_AverageDecodeTimeMs` smoothing window.
    var decodeTimeEmaSeconds: Double?
    static let decodeTimeEmaAlpha: Double = 0.1

    // FPS counters. We track running totals plus a window-start time and
    // window-start total; FPS = (total - windowStartTotal) / (now - windowStart).
    // The window-start values are reset only once a snapshot COMPLETES a window
    // (`now - windowStart >= minWindowSeconds`), so the reported FPS is the
    // average over the last ~1s sampling window even when the overlay reads at
    // 4 Hz - same shape as moonlight-qt's `STATS_INTERVAL` accumulators.
    /// Wall-clock of the last frame the native backend's receive thread
    /// handed us. Reception != decode: a host sending packets we can't
    /// decode (corrupted bitstream, missing IDR, AV1-on-no-AV1-hardware)
    /// is invisible to a reception-gated watchdog, so StreamSession's
    /// watchdog gates on `lastDecodedFrameTime`. This field lives on so
    /// the watchdog can distinguish "host silent" (no reception either)
    /// from "host sending but we can't decode" (reception fine, decode
    /// silent) and pick the right recovery (teardown vs. IDR-request).
    /// 0 means we haven't received our first frame yet.
    var lastReceivedFrameTime: CFAbsoluteTime = 0
    /// Wall-clock of the last frame VT successfully produced a CVPixelBuffer
    /// for. Set from the VT output callback on the success path.
    /// 0 means we haven't decoded our first frame yet.
    var lastDecodedFrameTime: CFAbsoluteTime = 0
    /// Wall-clock of the last frame actually handed to the renderer
    /// (`recordRendererEnqueue`). This is the MODE-AGNOSTIC present clock: the
    /// single `renderer.enqueue` site in `presentFrame` feeds it in BOTH the
    /// paced and the direct-enqueue paths, so the present-path watchdog can
    /// detect a screen freeze without depending on the pacer's liveness (which
    /// is nil in direct mode - the gap that let the direct path wedge with no
    /// recovery). 0 means we haven't presented our first frame yet.
    var lastPresentTime: CFAbsoluteTime = 0
    var receivedFrames: UInt64 = 0
    var decodedFrames: UInt64 = 0
    var decoderDroppedFrames: UInt64 = 0
    var renderedFrames: UInt64 = 0
    var receivedBytes: UInt64 = 0

    var windowStart: CFAbsoluteTime = 0
    var windowStartReceivedFrames: UInt64 = 0
    var windowStartDecodedFrames: UInt64 = 0
    var windowStartRenderedFrames: UInt64 = 0
    var windowStartReceivedBytes: UInt64 = 0

    /// All window-relative fields of the LAST COMPLETED ~1s slice, cached as one
    /// value. This is what lets the overlay tick FASTER than the FPS averaging
    /// window without the FPS numbers turning to noise: a `snapshot()` call made
    /// before the window has accumulated `minWindowSeconds` of data serves these
    /// cached values (last good ~1s average) instead of recomputing over a too-
    /// short slice (a 250ms slice at 4Hz swings displayed FPS by ±4 as a single
    /// frame lands in/out). The LIVE gauges (RTT, jitter, decode-time EMA, pacing
    /// depth, cumulative drops) are always recomputed every call, so the latency
    /// rows stay genuinely live. `nil` until the first window completes (sub-
    /// window reads before then render as em-dashes, not zeros).
    struct WindowCache {
        var receivedFps = 0.0
        var decodedFps = 0.0
        var renderedFps = 0.0
        var measuredBitrateMbps = 0.0
        var avgPresentCadenceErrorMs: Double?
        var maxPresentCadenceErrorMs: Double?
        var onTimePresentPercent: Double?
        var minHostProcessingLatencyMs: Double?
        var maxHostProcessingLatencyMs: Double?
        var avgHostProcessingLatencyMs: Double?
        var avgFrameBytes: Double?
        var maxFrameBytes: Int?
        var idrFramePercent: Double?
    }
    var windowCache: WindowCache?

    // Total-frame counters since reset(), retained so the "frames dropped by
    // decoder" percentage is over the whole stream, not just the current
    // sampling window. Cheap and gives the user a more stable number.
    var totalReceived: UInt64 = 0
    var totalDecoderDropped: UInt64 = 0
    /// Frames the renderer refused (isReadyForMoreMediaData=false) and we
    /// dropped to keep latency bounded. Counted separately from decoder-side
    /// drops because the failure mode is different: this is "OS-side queue
    /// got full, we're behind on display," not "VT rejected the bitstream".
    /// Used by the renderer-backpressure path in VideoDecoder.enqueueDecoded-
    /// Frame to surface "stream feels laggy after a while" diagnostics.
    var rendererBackpressureDrops: UInt64 = 0

    // ---- Frame-pacer smoothness counters ------------------------------------
    //
    // Populated by FramePacer on the decode queue (submit overflow) and on the
    // dedicated pacing queue (per-tick depth + per-present cadence). All under
    // the same lock as the rest of the collector. These power the overlay's
    // smoothness readout and the present-vs-PTS / drop-by-cause split.

    /// Frames dropped because the pacer could not present them in time - the
    /// jitter buffer overflowed (sustained lag) or the adaptive trim aged them
    /// out at a vsync. This is the NEW third drop cause, distinct from decoder
    /// drops (VT rejected the bitstream) and renderer-backpressure drops (the
    /// OS renderer queue was full). Session-cumulative.
    var presentationLateDrops: UInt64 = 0

    /// On-cadence presents this window: |cadence error| within tolerance of the
    /// stream's frame interval. Reset each snapshot alongside the FPS window.
    var onTimePresents: UInt64 = 0
    /// Off-cadence presents this window: |cadence error| past tolerance - the
    /// frame landed visibly early/late vs the ideal present grid.
    var latePresents: UInt64 = 0
    /// Running sum + count of |cadence error| (ms) for the window average.
    var presentCadenceErrorMsSum: Double = 0
    var presentCadenceSamples: UInt64 = 0
    /// Worst |cadence error| (ms) seen this window - the spike a user feels.
    var presentCadenceErrorMsMax: Double = 0
    /// Tolerance (ms) for the on-time/late split. 2ms is below the perceptual
    /// floor at every refresh we target (≈ a quarter-vsync at 120Hz) - inside
    /// it the present is indistinguishable from perfectly paced.
    static let presentCadenceToleranceMs: Double = 2.0

    /// Most-recently-sampled pacing queue depth (frames waiting for a vsync),
    /// sampled once per link tick. We surface the last value rather than an
    /// average because depth is a "how deep is the buffer right now" gauge, and
    /// the tick rate (60-240 Hz) is far above the 4Hz overlay read so the
    /// last-sample is representative. Live, surfaced every snapshot (NOT
    /// window-reset).
    var lastPacingDepth: Int = 0
    /// Peak pacing depth this window - surfaces a transient build the
    /// last-sample gauge would miss. Reset on each COMPLETED window (so it now
    /// tracks the peak across the full ~1s slice, not a sub-window read).
    var maxPacingDepth: Int = 0

    // Host-side capture + encode latency, as reported in each DECODE_UNIT's
    // `frameHostProcessingLatency` (1/10 ms units; 0 == no measurement).
    // This is a host-measured number - totally distinct from our own
    // `decodeTimeEmaSeconds`, which times VT submit → output on our side.
    // Tracking min / max / total / count lets the snapshot compute the same
    // min/max/avg triple moonlight-qt shows in its overlay. Window-relative:
    // we reset these on each COMPLETED window (~1s) along with the FPS counters
    // so the numbers reflect the current sampling window, not the whole session.
    // The computed min/max/avg are cached so a sub-window overlay read serves
    // the last good window rather than a too-short slice.
    var minHostProcessingLatency: UInt16 = 0  // 0 sentinel = unset
    var maxHostProcessingLatency: UInt16 = 0
    var totalHostProcessingLatency: UInt64 = 0
    var framesWithHostProcessingLatency: UInt64 = 0

    // Frame size + type (telemetry only): window-relative per-frame byte size +
    // IDR/P split, fed on the receive path so the exporter can publish avg/max
    // frame size + %IDR (the big-frame / recurring-IDR idle-spike hypothesis).
    // Reset each `snapshot()` with the FPS window; no overlay row.
    var windowFrameBytesSum: UInt64 = 0
    var windowFrameCount: UInt64 = 0
    var windowMaxFrameBytes: Int = 0
    var windowIdrFrameCount: UInt64 = 0

    var lock = os_unfair_lock_s()

    func reset() {
        // Drain any open signpost intervals before clearing the FIFO; without
        // this, a reset() between recordDecodeSubmit and recordDecodeComplete
        // would leak every still-open DecodeFrame interval.
        var leftover: [OSSignpostIntervalState] = []
        os_unfair_lock_lock(&lock)
        leftover.reserveCapacity(submitFifo.count)
        for entry in submitFifo { leftover.append(entry.state) }
        submitFifo.removeAll(keepingCapacity: true)
        decodeTimeEmaSeconds = nil
        receivedFrames = 0
        decodedFrames = 0
        decoderDroppedFrames = 0
        renderedFrames = 0
        receivedBytes = 0
        lastReceivedFrameTime = 0
        lastDecodedFrameTime = 0
        lastPresentTime = 0
        windowStart = CFAbsoluteTimeGetCurrent()
        windowStartReceivedFrames = 0
        windowStartDecodedFrames = 0
        windowStartRenderedFrames = 0
        windowStartReceivedBytes = 0
        windowCache = nil
        totalReceived = 0
        totalDecoderDropped = 0
        rendererBackpressureDrops = 0
        presentationLateDrops = 0
        onTimePresents = 0
        latePresents = 0
        presentCadenceErrorMsSum = 0
        presentCadenceSamples = 0
        presentCadenceErrorMsMax = 0
        lastPacingDepth = 0
        maxPacingDepth = 0
        minHostProcessingLatency = 0
        maxHostProcessingLatency = 0
        totalHostProcessingLatency = 0
        framesWithHostProcessingLatency = 0
        windowFrameBytesSum = 0; windowFrameCount = 0
        windowMaxFrameBytes = 0; windowIdrFrameCount = 0
        os_unfair_lock_unlock(&lock)
        for state in leftover {
            OSSignposter.decode.endInterval(
                "DecodeFrame", state, "outcome=reset")
        }
    }

    /// Snapshot the collector for the overlay / telemetry.
    ///
    /// `minWindowSeconds` DECOUPLES the FPS-averaging window from the caller's
    /// tick rate. The window-relative fields (FPS, measured bitrate, present
    /// cadence, host-processing latency, frame size) are only RECOMPUTED + the
    /// window only SLID once at least `minWindowSeconds` have elapsed since the
    /// last slide; calls in between serve those fields from the cached last-
    /// completed-window values. The LIVE gauges (decode-time EMA, RTT/jitter -
    /// added by the caller, pacing depth, cumulative drop percentages) are
    /// recomputed EVERY call. The result: the overlay can tick at 4 Hz so the
    /// latency rows feel live, while FPS keeps its stable ~1 s average instead
    /// of the ±4fps noise a 250 ms window would show.
    ///
    /// Pass `minWindowSeconds = 0` (the default) to preserve the original
    /// reset-on-every-read behaviour - the telemetry exporter calls it that way
    /// so its NDJSON keeps emitting fresh per-tick windows on its own cadence.
    func snapshot(minWindowSeconds: Double = 0) -> StreamStatsSnapshot {
        let now = CFAbsoluteTimeGetCurrent()
        os_unfair_lock_lock(&lock)
        defer { os_unfair_lock_unlock(&lock) }

        var snap = StreamStatsSnapshot()

        // Slide + recompute the window-relative cache only once the window has
        // accumulated at least `minWindowSeconds` of data (50ms floor for the
        // reset-every-call minWindowSeconds==0 path). Sub-window reads keep the
        // accumulators intact so the in-progress slice builds toward the window.
        if now - windowStart >= max(minWindowSeconds, 0.05) {
            recomputeWindowCacheAndSlide(now: now)
        }

        // Serve the window-relative fields from the cache (just refreshed above
        // on a completed window; otherwise the last good ~1s average). Stays nil
        // until the first window completes so the very first sub-window reads
        // render as em-dashes rather than zeros.
        if let cache = windowCache {
            snap.receivedFps = cache.receivedFps
            snap.decodedFps = cache.decodedFps
            snap.renderedFps = cache.renderedFps
            snap.measuredBitrateMbps = cache.measuredBitrateMbps
            snap.avgPresentCadenceErrorMs = cache.avgPresentCadenceErrorMs
            snap.maxPresentCadenceErrorMs = cache.maxPresentCadenceErrorMs
            snap.onTimePresentPercent = cache.onTimePresentPercent
            snap.minHostProcessingLatencyMs = cache.minHostProcessingLatencyMs
            snap.maxHostProcessingLatencyMs = cache.maxHostProcessingLatencyMs
            snap.avgHostProcessingLatencyMs = cache.avgHostProcessingLatencyMs
            snap.avgFrameBytes = cache.avgFrameBytes
            snap.maxFrameBytes = cache.maxFrameBytes
            snap.idrFramePercent = cache.idrFramePercent
        }

        // ---- LIVE gauges - recomputed every call regardless of the window ----
        if let ema = decodeTimeEmaSeconds {
            snap.avgDecodeTimeMs = ema * 1000.0
        }
        if totalReceived > 0 {
            snap.decoderDroppedPercent = Double(totalDecoderDropped) / Double(totalReceived) * 100.0
        }
        // Pacing depth is a live "how deep is the buffer right now" gauge,
        // sampled once per link tick (60-240 Hz, far above the overlay read).
        snap.pacingQueueDepth = lastPacingDepth
        snap.pacingQueueDepthMax = maxPacingDepth
        snap.presentationLateDrops = presentationLateDrops

        return snap
    }

    /// Recompute the window-relative fields over the freshly completed slice,
    /// CACHE them (so sub-window reads serve the last good ~1s average rather
    /// than a noisy short slice), then slide the window start forward and reset
    /// the window-scoped accumulators. MUST be called with `lock` held (the only
    /// caller is `snapshot()`, inside its lock). Factored out of `snapshot()` to
    /// keep that function under the body-length budget.
    private func recomputeWindowCacheAndSlide(now: CFAbsoluteTime) {
        let windowDuration = now - windowStart
        var cache = WindowCache()
        cache.receivedFps = Double(receivedFrames &- windowStartReceivedFrames) / windowDuration
        cache.decodedFps = Double(decodedFrames &- windowStartDecodedFrames) / windowDuration
        cache.renderedFps = Double(renderedFrames &- windowStartRenderedFrames) / windowDuration
        // Bytes → Mbps: bytes * 8 / 1_000_000 / seconds. Use 1_000_000 (not
        // 1024*1024) to match how every other tool - including moonlight-qt's
        // `Bitrate: X Mbps` row - reports it.
        let dBytes = receivedBytes &- windowStartReceivedBytes
        cache.measuredBitrateMbps = (Double(dBytes) * 8.0) / 1_000_000.0 / windowDuration

        // ---- Frame-pacer smoothness (window-relative) ----
        if presentCadenceSamples > 0 {
            cache.avgPresentCadenceErrorMs = presentCadenceErrorMsSum / Double(presentCadenceSamples)
            cache.maxPresentCadenceErrorMs = presentCadenceErrorMsMax
            let total = onTimePresents + latePresents
            if total > 0 { cache.onTimePresentPercent = Double(onTimePresents) / Double(total) * 100.0 }
        }

        // Host processing latency (window-scoped). Only surface if we saw at
        // least one frame with a non-zero host-side measurement this window;
        // otherwise the overlay row renders as an em-dash. Convert the
        // tenths-of-ms units the host reports into floating-point ms.
        if framesWithHostProcessingLatency > 0 {
            cache.minHostProcessingLatencyMs = Double(minHostProcessingLatency) / 10.0
            cache.maxHostProcessingLatencyMs = Double(maxHostProcessingLatency) / 10.0
            cache.avgHostProcessingLatencyMs =
                Double(totalHostProcessingLatency) / 10.0 / Double(framesWithHostProcessingLatency)
        }

        // Frame size + type (telemetry only).
        if windowFrameCount > 0 {
            cache.avgFrameBytes = Double(windowFrameBytesSum) / Double(windowFrameCount)
            cache.maxFrameBytes = windowMaxFrameBytes
            cache.idrFramePercent = Double(windowIdrFrameCount) / Double(windowFrameCount) * 100.0
        }
        windowCache = cache

        // Slide the window start forward + reset window-scoped accumulators.
        // `lastPacingDepth` is a live gauge (NOT reset); `presentationLateDrops`
        // is session-cumulative (NOT reset).
        windowStart = now
        windowStartReceivedFrames = receivedFrames
        windowStartDecodedFrames = decodedFrames
        windowStartRenderedFrames = renderedFrames
        windowStartReceivedBytes = receivedBytes
        minHostProcessingLatency = 0
        maxHostProcessingLatency = 0
        totalHostProcessingLatency = 0
        framesWithHostProcessingLatency = 0
        windowFrameBytesSum = 0; windowFrameCount = 0
        windowMaxFrameBytes = 0; windowIdrFrameCount = 0
        onTimePresents = 0
        latePresents = 0
        presentCadenceErrorMsSum = 0
        presentCadenceSamples = 0
        presentCadenceErrorMsMax = 0
        maxPacingDepth = 0
    }
}
