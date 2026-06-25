//
//  TelemetryLatency.swift
//
//  Per-stage video latency breakdown for the opt-in telemetry rig. Captures, per
//  frame, the monotonic timestamps at the four pipeline stages and turns them
//  into (a) Prometheus-style HISTOGRAMS (so the exporter emits queryable
//  p50/p95/p99 per stage via `histogram_quantile`) and (b) a PER-FRAME NDJSON
//  trace written batched OFF the hot path. See TelemetryExporter.swift for the
//  gate/safety contract; this file is the latency half of that rig.
//
//  STAGES (all captured with a cheap monotonic read - `DispatchTime.now()` wraps
//  mach_absolute_time):
//    * t_receive  - last packet of the frame arrived (RtpVideoQueue → the
//                   depacketizer's `firstPacketReceiveTimeUs`, already captured).
//    * t_assemble - depacketizer completed the access unit (reassembleFrame, the
//                   DecodeUnit's `enqueueTimeUs`, already captured).
//    * t_submit   - handed to VTDecompressionSessionDecodeFrame (VideoDecoder).
//    * t_output   - VT output callback produced a CVPixelBuffer (VideoDecoder).
//    * t_present  - renderer.enqueue (FramePacer → VideoDecoder.presentFrame).
//  Deltas: receive→assemble, assemble→submit, submit→output (decode),
//  output→present (pacing), and end-to-end receive→present.
//
//  HOT-PATH SAFETY + GATING (load-bearing - zero-overhead when OFF):
//    * `FrameTimingTracker.shared` is nil unless the gate is on. Every stage call
//      site is `if let tracker = FrameTimingTracker.shared { ... }`, so when OFF the
//      cost is a single nil-optional load - NO allocation, NO lock, NO map.
//    * When ON, ONE bounded map (keyed by the frame's rtpTimestamp, which is the
//      only frame identity that survives the VideoToolbox boundary - frameNumber
//      is lost once the sample's PTS is all VT propagates to its output callback)
//      tracks in-flight frames. It is guarded by ONE os_unfair_lock - a new lock,
//      but NOT a hot-path lock on the proven decode/pace path: the existing
//      StatsCollector / FramePacer / depacketizer locks are untouched, and this
//      lock is only taken on the (already off-by-default) telemetry path.
//    * The map is bounded: stale entries (a dropped / never-presented frame) are
//      evicted in FIFO insertion order so a leak is impossible.
//    * The histograms are fixed-bucket atomic counters - a stage record is a
//      branchless bucket find + one locked add. No per-frame allocation.
//    * The per-frame NDJSON record is appended to an in-memory buffer and flushed
//      by a ~250ms background timer - NEVER an fsync (or even a write) on the hot
//      path.
//
//  SECRET-FREE: every value here is a nanosecond delta or a frame index. Nothing
//  that could carry a secret, key, or host identity.
//

import Foundation
import os

// MARK: - Latency histograms

/// Fixed-bucket, atomic-increment histograms for the five latency stages. We use
/// real Prometheus histograms (`_bucket`/`_sum`/`_count`) rather than
/// pre-computed `_p50/_p95/_p99` gauges because it is BOTH lower-overhead on the
/// hot path AND more queryable: a record is a branchless bucket find + a single
/// locked add (no sorted reservoir / live-quantile maintenance per frame), and
/// Grafana derives p50/p95/p99 from the cumulative buckets with
/// `histogram_quantile(0.95, rate(..._bucket[1m]))`. Cardinality stays low - five
/// families, ~12 buckets each, one `{session}` label.
///
/// `@unchecked Sendable`: every counter is its own `os_unfair_lock`-guarded
/// UInt64 (the same discipline as `TelemetryCounters.Counter`), safe from the
/// receive thread, the decode queue, and the pacer's serial queue.
final class LatencyHistograms: @unchecked Sendable {

    /// One stage's cumulative histogram: per-bucket counts (Prometheus `le`
    /// semantics - bucket[i] counts observations ≤ bounds[i]), plus running sum
    /// (ms) and total count. One lock per stage keeps the five stages
    /// contention-free against each other.
    final class Stage: @unchecked Sendable {
        /// Upper bounds in MILLISECONDS. Chosen to span the realistic per-stage
        /// range for 60-240fps streaming: sub-ms assemble/submit jitter through
        /// to multi-frame decode/pace stalls. The implicit `+Inf` bucket (count
        /// vs total) is emitted by the renderer.
        ///
        /// FINE LOW/MID RESOLUTION where it matters: the e2e pipeline lands at
        /// ~5-6ms, and the old [4,8,16] spacing left a 4→8→16 gap (a ~12ms-wide
        /// "blur" bucket) right across that range, so p50/p95/p99 had no real
        /// resolution exactly where the signal lives. The bounds below add
        /// sub-ms and few-ms edges (0.1...6) so quantiles resolve to sub-ms / few-ms
        /// precision, while the coarse tail (8...528) still captures multi-frame
        /// stalls. boundsMs is read by both the Prometheus render and the NDJSON
        /// quantile estimator, so this single edit propagates to all consumers.
        static let boundsMs: [Double] = [
            0.1, 0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4, 5, 6, 8, 10, 12, 16, 33, 66, 132, 264, 528
        ]

        /// COARSE bounds for the wide-range composite stages (glass-to-glass,
        /// input-to-photon). These span the realistic end-user latency budget:
        /// a few ms (LAN, light host encode) through tens of ms (host AV1
        /// two-pass encode) into the hundreds (a saturated link or a stalled
        /// frame). Resolution is concentrated in the 5-60ms zone where "feels
        /// great" turns into "feels laggy", with a coarse tail to 1056ms so a
        /// pathological stall still lands in a bucket rather than overflowing to
        /// +Inf with no shape.
        static let glassToGlassBoundsMs: [Double] = [
            1, 2, 4, 6, 8, 10, 12, 16, 20, 25, 30, 40, 50, 66, 90, 132, 200, 300, 528, 1056
        ]

        /// OUTPUT→PRESENT (pacing) bounds. The default `boundsMs` jumps 16→33→66, a
        /// blind ~30ms bucket right where the pacing tail lives (multi-vsync holds land
        /// at 17-42ms), so p95/p99 had no resolution there. Adds 20/25/40/50 across it.
        static let outputToPresentBoundsMs: [Double] = [
            0.1, 0.25, 0.5, 0.75, 1, 1.5, 2, 3, 4, 5, 6, 8, 10, 12, 16, 20, 25, 33, 40, 50, 66, 132, 264, 528
        ]

        /// The bounds THIS stage buckets against. Per-stage so the fine sub-stage
        /// histograms and the coarse composite ones share one observe/snapshot
        /// path; read by both the Prometheus render and the NDJSON quantile
        /// estimator (carried on the snapshot) so they stay consistent.
        let bounds: [Double]

        private let lock = os_unfair_lock_t.allocate(capacity: 1)
        private var bucketCounts: [UInt64]
        private var sumMs: Double = 0
        private var totalCount: UInt64 = 0

        init(bounds: [Double] = Stage.boundsMs) {
            self.bounds = bounds
            lock.initialize(to: os_unfair_lock_s())
            bucketCounts = [UInt64](repeating: 0, count: bounds.count)
        }
        deinit { lock.deallocate() }

        /// Record one observation (a stage delta, in ms). Branchless-ish bucket
        /// find over a 12-element ascending array, then a single locked update of
        /// the matching cumulative buckets + sum + count.
        func observe(_ valueMs: Double) {
            guard valueMs.isFinite, valueMs >= 0 else { return }
            os_unfair_lock_lock(lock)
            // Cumulative ("le") semantics: increment every bucket whose bound is
            // ≥ the value. Walk from the smallest bound up; once we pass the
            // value, all remaining (larger) buckets also count it.
            var index = 0
            let bounds = self.bounds
            while index < bounds.count {
                if valueMs <= bounds[index] {
                    // From here up, every bucket's bound is larger, so all of
                    // them include this observation.
                    while index < bounds.count {
                        bucketCounts[index] &+= 1
                        index += 1
                    }
                    break
                }
                index += 1
            }
            sumMs += valueMs
            totalCount &+= 1
            os_unfair_lock_unlock(lock)
        }

        /// Snapshot the cumulative buckets + sum + count for rendering. Taken on
        /// the exporter's serial queue (1Hz), not the hot path.
        func snapshot() -> (buckets: [UInt64], sumMs: Double, count: UInt64) {
            os_unfair_lock_lock(lock); defer { os_unfair_lock_unlock(lock) }
            return (bucketCounts, sumMs, totalCount)
        }

        func reset() {
            os_unfair_lock_lock(lock)
            for index in bucketCounts.indices { bucketCounts[index] = 0 }
            sumMs = 0
            totalCount = 0
            os_unfair_lock_unlock(lock)
        }
    }

    let receiveToAssemble = Stage()
    let assembleToSubmit = Stage()
    let submitToOutput = Stage()
    let outputToPresent = Stage(bounds: Stage.outputToPresentBoundsMs)
    let endToEnd = Stage()

    /// DECODE time split by frame type (signal: DECODE). The submit→output
    /// (VTDecompressionSessionDecodeFrame → output callback) delta, bucketed
    /// SEPARATELY for IDR keyframes vs P-frames. An IDR is a full-resolution
    /// intra frame and decodes much slower than a delta P-frame, so the combined
    /// `submitToOutput` histogram blurs two distributions; splitting them shows
    /// the true per-type decode cost and catches an IDR-decode-cost spike (the
    /// recurring-IDR-on-idle-resume hypothesis) that the blended view hides. Both
    /// use the fine sub-stage bounds (decode lands in the few-ms range).
    let decodeIDR = Stage()
    let decodeP = Stage()

    /// IDR/RFI ROUND-TRIP (signal: IDR-RTT). Time from our requestIdrFrame/RFI
    /// SEND to the matching IDR/recovery frame ARRIVING (both client-side). Spans
    /// a network round trip plus the host's encode of a full intra frame, so it
    /// uses the coarse composite bounds (a recovery on a bad link is tens to
    /// hundreds of ms). Fed once per matched request from the depacketizer.
    let idrRoundTrip = Stage(bounds: Stage.glassToGlassBoundsMs)

    /// GLASS-TO-GLASS: the "how good is it" number - host capture+encode
    /// (Sunshine `frameHostProcessingLatency`) + network transit (~RTT/2) + our
    /// pipeline (receive→present, the endToEnd stage). Computed per frame at
    /// present and recorded here so the exporter publishes p50/p95/p99 over time.
    /// Spans a much wider range than any single sub-stage (host AV1 encode alone
    /// can be tens of ms), so it gets its own coarse-tailed bound set below.
    let glassToGlass = Stage(bounds: Stage.glassToGlassBoundsMs)

    /// INPUT-TO-PHOTON (estimate): a LOWER BOUND on felt input latency -
    /// (next-presented-frame-time − last-input-sent-time). Labelled an estimate
    /// because the host doesn't mark which frame reflects an input. Same wide
    /// range as glass-to-glass (it includes the full host round trip plus the
    /// time the input waited for the next frame), so it shares the coarse bounds.
    let inputToPhoton = Stage(bounds: Stage.glassToGlassBoundsMs)

    func reset() {
        receiveToAssemble.reset()
        assembleToSubmit.reset()
        submitToOutput.reset()
        outputToPresent.reset()
        endToEnd.reset()
        glassToGlass.reset()
        inputToPhoton.reset()
        decodeIDR.reset()
        decodeP.reset()
        idrRoundTrip.reset()
    }

    /// Capture all stages into a plain value snapshot for the exporter to render.
    /// Taken on the exporter's serial queue (1Hz) - never the hot path.
    func snapshot() -> LatencyHistogramSnapshot {
        func stage(_ source: Stage) -> LatencyHistogramSnapshot.Stage {
            let captured = source.snapshot()
            return LatencyHistogramSnapshot.Stage(
                buckets: captured.buckets, boundsMs: source.bounds,
                sumMs: captured.sumMs, observationCount: captured.count)
        }
        return LatencyHistogramSnapshot(
            receiveToAssemble: stage(receiveToAssemble),
            assembleToSubmit: stage(assembleToSubmit),
            submitToOutput: stage(submitToOutput),
            outputToPresent: stage(outputToPresent),
            endToEnd: stage(endToEnd),
            glassToGlass: stage(glassToGlass),
            inputToPhoton: stage(inputToPhoton),
            decodeIDR: stage(decodeIDR),
            decodeP: stage(decodeP),
            idrRoundTrip: stage(idrRoundTrip))
    }
}

// The `LatencyHistogramSnapshot` plain value type (the per-tick snapshot of every
// stage's cumulative buckets) lives in TelemetryLatencySnapshot.swift, split out
// so this file stays under the length budget and focused on the live histograms +
// the per-frame tracker.

// MARK: - Per-frame timing tracker

/// The bounded, gate-allocated per-frame timing map + its feeds into the
/// histograms and the per-frame trace. `shared` is the single gate-checked
/// instance: it is non-nil ONLY when telemetry is enabled, so the hot-path call
/// sites pay a single optional load when off (no map, no lock, no allocation).
///
/// KEYING - frames are keyed by `rtpTimestamp` (the host's 90kHz capture-clock
/// PTS). This is the only identity that survives the VideoToolbox boundary: the
/// frameNumber is dropped once the sample is built, and all VT propagates to its
/// output callback is the sample's PTS (`CMTimeMake(rtpTimestamp, 90000)`), which
/// the present path also carries on the CMSampleBuffer. For low-latency game
/// streaming (no B-frames, strictly-advancing capture clock) the rtpTimestamp is
/// effectively unique per frame. A rtpTimestamp of 0 (older Sunshine / defensive
/// path) is treated as "untracked" - those frames simply get no latency record.
///
/// `@unchecked Sendable`: the map is guarded by one `os_unfair_lock`; the
/// histograms + trace writer are themselves Sendable.
final class FrameTimingTracker: @unchecked Sendable {

    /// The gate-checked singleton. `start()` installs it iff telemetry is on;
    /// `stop()` clears it. Read on the hot path as `FrameTimingTracker.shared`.
    /// `nonisolated(unsafe)`: written only at session start/teardown (single
    /// writer, well-ordered against the reads), read everywhere - the same
    /// discipline the decoder's other `nonisolated(unsafe)` slots use.
    nonisolated(unsafe) static var shared: FrameTimingTracker?

    /// Install a fresh tracker iff the gate is on, and start its trace writer.
    /// Called from the exporter's `start()`. No-op (and nothing installed) when
    /// off, so `shared` stays nil and the hot path stays zero-cost.
    static func startIfEnabled(sessionId: String, isoStamp: String) {
        guard TelemetryGate.isEnabled else { return }
        let tracker = FrameTimingTracker(sessionId: sessionId)
        tracker.traceWriter.start(isoStamp: isoStamp)
        shared = tracker
    }

    /// Tear down + clear the singleton. Flushes + closes the trace writer.
    static func stop() {
        let tracker = shared
        shared = nil
        tracker?.traceWriter.stop()
    }

    // ---- Instance state (only exists when enabled) ----

    let histograms = LatencyHistograms()
    /// Both internal (not private): the trace renderer + drop-stub emitter in
    /// TelemetryLatency+Trace.swift are the only cross-file consumers.
    let traceWriter = FrameTraceWriter()
    let sessionId: String

    /// One in-flight frame's stage timestamps (nanoseconds, monotonic uptime).
    /// receive + assemble are filled at `recordAssembled` (both are already
    /// captured upstream); submit/output/present fill as the frame advances.
    /// Module-internal so the drop-stub emitter (+Trace.swift) can read it.
    struct Timing {
        let frameIndex: Int32
        let receiveNanos: UInt64
        let assembleNanos: UInt64
        /// On-the-wire frame size (bytes) + keyframe flag, captured at assemble so
        /// the per-frame trace can carry size + IDR/P type - the signal that
        /// excludes / catches a big-frame or recurring-IDR spike on idle resume.
        let frameBytes: Int32
        let isIDR: Bool
        /// Host capture+encode latency for THIS frame (ms), from Sunshine's
        /// `frameHostProcessingLatency` (1/10 ms on the wire → ms here). 0 == the
        /// host didn't measure this frame (repeated frame / GFE), in which case
        /// glass-to-glass omits the host-encode leg rather than guessing. Captured
        /// at assemble (it rides the DecodeUnit) so glass-to-glass is per-frame.
        let hostEncodeMs: Double
        var submitNanos: UInt64 = 0
        var outputNanos: UInt64 = 0
    }

    /// STARTUP WARMUP GATE (metric honesty - ingestion only). The histograms are
    /// CUMULATIVE session-lifetime (totalCount only grows, reset once at session
    /// start), so the bad first several seconds of encoder-ramp / link-onset frames
    /// stay baked into the g2g/o2p percentiles for as long as the cumulative tail
    /// takes to age out - making the start-chug LOOK several times worse than it
    /// FELT (felt percentiles recover quickly). So onset frames are DROPPED from
    /// histogram INGESTION for a short grace after the FIRST present (anchored
    /// there, not at tracker creation, so an idle gap before the stream doesn't
    /// consume the budget).
    /// MEASUREMENT-ONLY: pacer, jitter buffer, safeguards, freeze recovery, and the
    /// per-frame NDJSON trace (still records onset frames) are ALL untouched - only
    /// the cumulative `observe()` calls are skipped.
    /// (Module-internal, not private: the consume-once input-to-photon gate in
    /// TelemetryLatency+Composites.swift rides this same present-path lock.)
    let warmupLock = os_unfair_lock_t.allocate(capacity: 1)
    private var firstPresentNanos: UInt64 = 0
    /// Grace (ns) after the first present during which onset frames are excluded
    /// from histogram ingestion. ~1.25s - covers encoder ramp + link onset, short
    /// enough that steady-state samples dominate immediately after.
    private static let warmupGraceNanos: UInt64 = 1_250_000_000

    /// True while still inside the post-first-present warmup grace (this onset frame
    /// is EXCLUDED from histogram ingestion). Seeds the anchor on the first call.
    /// One short lock on the already-gate-on present path; never the decode/pace path.
    private func isWithinWarmup(presentNanos: UInt64) -> Bool {
        os_unfair_lock_lock(warmupLock); defer { os_unfair_lock_unlock(warmupLock) }
        if firstPresentNanos == 0 {
            firstPresentNanos = presentNanos
            return true
        }
        return presentNanos &- firstPresentNanos < Self.warmupGraceNanos
    }

    /// RESUME-PRESENT tag (metric honesty, ingestion-only - the warmup gate's
    /// sibling): armed at the un-suppress edge (`setPresentSuppressed`),
    /// consumed by the NEXT present, which re-shows the retained frame - its
    /// o2p/g2g carries the DESIGNED hold time (a long resume hold otherwise
    /// polluted the percentiles as a fake spike). Tagged frames skip histogram
    /// ingestion but still land in the trace with `resume:true` - recorded,
    /// just not averaged. Rides `warmupLock`; per-session by construction.
    private var resumePresentPending = false
    /// Most recent input stamp already CONSUMED by an input-to-photon
    /// observation (consume-once; see computeInputToPhoton in the Composites
    /// split). Module-internal + rides `warmupLock` so the split can reach both.
    var lastInputConsumedNanos: UInt64 = 0
    func armResumePresentTag() {
        os_unfair_lock_lock(warmupLock); resumePresentPending = true; os_unfair_lock_unlock(warmupLock)
    }
    private func takeResumePresentTag() -> Bool {
        os_unfair_lock_lock(warmupLock); defer { os_unfair_lock_unlock(warmupLock) }
        let pending = resumePresentPending; resumePresentPending = false
        return pending
    }

    /// The bounded map, keyed by rtpTimestamp. Guarded by `mapLock`.
    private let mapLock = os_unfair_lock_t.allocate(capacity: 1)
    private var inFlight: [UInt32: Timing] = [:]
    /// Insertion order of the keys, so eviction drops the STALEST in-flight frame
    /// (a dropped / never-presented frame) when the map exceeds its bound.
    private var insertionOrder: [UInt32] = []

    /// Map bound. ~256 in-flight frames is far beyond the real pipeline depth
    /// (decode backlog + pacer queue are each ~tens of frames), so a healthy
    /// stream never evicts; the bound exists purely so a frame that is received
    /// but never presented (dropped at decode or pacing) can't leak.
    private static let maxInFlight = 256

    private init(sessionId: String) {
        self.sessionId = sessionId
        mapLock.initialize(to: os_unfair_lock_s())
        warmupLock.initialize(to: os_unfair_lock_s())
    }
    deinit { mapLock.deallocate(); warmupLock.deallocate() }

    // MARK: Stage records (called from the existing hot-path call sites)

    /// Stage t_receive + t_assemble. Called from the depacketizer the instant a
    /// frame's access unit is complete (VideoRtpReceiver.depacketizerDidAssemble-
    /// Frame). Both timestamps are ALREADY captured upstream - `receiveNanos` is
    /// the frame's last/first-packet arrival (`firstPacketReceiveTimeUs`) and
    /// `assembleNanos` is the reassemble instant (`enqueueTimeUs`) - so this adds
    /// no new clock read, just a map insert. Establishes the entry the later
    /// stages look up by rtpTimestamp.
    func recordAssembled(rtpTimestamp: UInt32, frameIndex: Int32,
                         receiveNanos: UInt64, assembleNanos: UInt64,
                         frameBytes: Int32 = 0, isIDR: Bool = false,
                         hostEncodeTenthsMs: UInt16 = 0) {
        guard rtpTimestamp != 0 else { return }
        let timing = Timing(frameIndex: frameIndex,
                            receiveNanos: receiveNanos,
                            assembleNanos: assembleNanos,
                            frameBytes: frameBytes,
                            isIDR: isIDR,
                            hostEncodeMs: Double(hostEncodeTenthsMs) / 10.0)
        os_unfair_lock_lock(mapLock)
        if inFlight[rtpTimestamp] == nil {
            insertionOrder.append(rtpTimestamp)
        }
        inFlight[rtpTimestamp] = timing
        // Bound the map: evict the stalest in-flight frame(s) - frames received
        // but dropped before present, which would otherwise leak. Evictions
        // become frames-file DROP STUBS, emitted off the lock (emitDropStubs).
        var evicted: [(rtp: UInt32, timing: Timing)] = []
        while insertionOrder.count > Self.maxInFlight {
            let stale = insertionOrder.removeFirst()
            if let dropped = inFlight.removeValue(forKey: stale) { evicted.append((stale, dropped)) }
        }
        os_unfair_lock_unlock(mapLock)
        if !evicted.isEmpty { emitDropStubs(evicted) }
    }

    /// Stage t_submit. Called just before VTDecompressionSessionDecodeFrame
    /// (VideoDecoder.submitSampleToVT) with one cheap monotonic read.
    func recordSubmit(rtpTimestamp: UInt32) {
        guard rtpTimestamp != 0 else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        os_unfair_lock_lock(mapLock)
        if inFlight[rtpTimestamp] != nil {
            inFlight[rtpTimestamp]?.submitNanos = now
        }
        os_unfair_lock_unlock(mapLock)
    }

    /// Stage t_output. Called from the VT output callback (VideoDecoder's
    /// decompressionOutputCallback) with the recovered rtpTimestamp.
    func recordOutput(rtpTimestamp: UInt32) {
        guard rtpTimestamp != 0 else { return }
        let now = DispatchTime.now().uptimeNanoseconds
        os_unfair_lock_lock(mapLock)
        if inFlight[rtpTimestamp] != nil {
            inFlight[rtpTimestamp]?.outputNanos = now
        }
        os_unfair_lock_unlock(mapLock)
    }

    /// Stage t_present. Called the instant the frame is enqueued to the renderer
    /// (VideoDecoder.presentFrame). Looks up the entry, computes the five deltas,
    /// feeds the histograms, appends the per-frame trace line, and EVICTS the
    /// entry (so a presented frame can never leak).
    func recordPresent(rtpTimestamp: UInt32) {
        guard rtpTimestamp != 0 else { return }
        let presentNanos = DispatchTime.now().uptimeNanoseconds

        os_unfair_lock_lock(mapLock)
        guard let timing = inFlight.removeValue(forKey: rtpTimestamp) else {
            os_unfair_lock_unlock(mapLock)
            return
        }
        // Drop the key from the insertion order too (linear, but the array is
        // bounded at maxInFlight and present is off the proven path).
        if let idx = insertionOrder.firstIndex(of: rtpTimestamp) {
            insertionOrder.remove(at: idx)
        }
        os_unfair_lock_unlock(mapLock)

        // Compute the five sub-stage deltas in ms. A stage timestamp of 0 means
        // the frame skipped that stage (shouldn't happen for a presented frame,
        // but guard so a partial entry can't emit a garbage delta).
        let receiveToAssemble = msBetween(timing.receiveNanos, timing.assembleNanos)
        let assembleToSubmit = msBetween(timing.assembleNanos, timing.submitNanos)
        let submitToOutput = msBetween(timing.submitNanos, timing.outputNanos)
        let outputToPresent = msBetween(timing.outputNanos, presentNanos)
        let endToEnd = msBetween(timing.receiveNanos, presentNanos)

        // STARTUP WARMUP GATE (metric honesty, ingestion-only): exclude the first
        // ~1.25s of presented (onset) frames from the CUMULATIVE histograms so the
        // encoder-ramp / link-onset chug doesn't stay baked into the session-lifetime
        // percentiles; the RESUME-PRESENT tag applies the same traced-not-ingested
        // contract to the first present after un-suppress (designed hold time).
        let resumePresent = takeResumePresentTag()
        let warmingUp = isWithinWarmup(presentNanos: presentNanos) || resumePresent

        if !warmingUp {
            if let value = receiveToAssemble { histograms.receiveToAssemble.observe(value) }
            if let value = assembleToSubmit { histograms.assembleToSubmit.observe(value) }
            if let value = submitToOutput { histograms.submitToOutput.observe(value) }
            if let value = outputToPresent { histograms.outputToPresent.observe(value) }
            if let value = endToEnd { histograms.endToEnd.observe(value) }

            // DECODE time split by frame type (signal: DECODE): the SAME submit→output
            // decode delta, routed to the IDR or P histogram by this frame's type so
            // the slow full-intra IDR decode doesn't blur the fast P-frame distribution
            // (and an IDR-decode-cost spike on idle-resume stays legible). No extra
            // clock read - reuses the value already computed above.
            if let value = submitToOutput {
                if timing.isIDR { histograms.decodeIDR.observe(value) } else { histograms.decodeP.observe(value) }
            }
        }

        // GLASS-TO-GLASS (signal 1): host capture+encode + network transit
        // (~RTT/2) + our pipeline (receive→present == endToEnd). Each leg is
        // independently optional - we sum only the legs we actually have so a
        // missing host-encode measurement (repeated frame) or a not-yet-known RTT
        // degrades the number rather than dropping it. The RTT read is the CURRENT
        // smoothed value (the host doesn't mark per-frame transit), taken from the
        // 1Hz-refreshed gauge; one short lock, only on this gate-on path. Computed
        // even during warmup so the trace carries it; ingested only after warmup.
        let glassToGlass = computeGlassToGlass(hostEncodeMs: timing.hostEncodeMs, pipelineMs: endToEnd)
        if !warmingUp, let value = glassToGlass { histograms.glassToGlass.observe(value) }

        // INPUT-TO-PHOTON estimate (signal 2): time from the last input batch
        // we sent to the FIRST present after it - a lower bound on felt input
        // latency. The host doesn't tell us which frame reflects an input, so
        // this is explicitly an estimate; each input stamp records at most one
        // observation (consume-once - see the Composites split), so an idle
        // stream's static frames can't inflate the metric and a genuinely slow
        // outlier isn't capped away.
        let inputToPhoton = computeInputToPhoton(presentNanos: presentNanos)
        if !warmingUp, let value = inputToPhoton { histograms.inputToPhoton.observe(value) }

        traceWriter.append(renderTraceLine(TraceRecord(
            frameIndex: timing.frameIndex,
            rtpTimestamp: rtpTimestamp,
            frameBytes: timing.frameBytes,
            isIDR: timing.isIDR,
            presentUptimeMs: Double(presentNanos) / 1_000_000.0,
            isResumePresent: resumePresent,
            receiveToAssemble: receiveToAssemble,
            assembleToSubmit: assembleToSubmit,
            submitToOutput: submitToOutput,
            outputToPresent: outputToPresent,
            endToEnd: endToEnd,
            glassToGlass: glassToGlass,
            inputToPhoton: inputToPhoton)))
    }

    /// Record one IDR/RFI ROUND-TRIP observation (signal: IDR-RTT). Called from
    /// the depacketizer the instant a requested IDR/recovery frame is assembled,
    /// with the measured request→arrival delta (ms) the always-live
    /// `P2State.resolveIdrArrival` computed. Feeds the histogram + an explicit
    /// per-frame trace event line (distinct from the per-frame latency lines, via
    /// the `event` key) so a reader greps the exact recovery beat. Off the proven
    /// path - an IDR arrival is rare.
    func recordIdrRoundTrip(frameIndex: Int32, roundTripMs: Double) {
        guard roundTripMs.isFinite, roundTripMs >= 0 else { return }
        histograms.idrRoundTrip.observe(roundTripMs)
        traceWriter.append(
            "{\"session\":\"\(sessionId)\",\"event\":\"idr_round_trip\","
            + "\"frame\":\(frameIndex),\"idr_round_trip_ms\":\(jsonNumber(roundTripMs))}")
    }

    // The COMPOSITE stage computations (glass-to-glass + the consume-once
    // input-to-photon estimate) live in TelemetryLatency+Composites.swift -
    // topic split to keep this file under the length budget.

    /// Delta in milliseconds between two monotonic-nanosecond stamps, or nil if
    /// either is unset (0) or the delta is negative (clock skew / partial entry).
    private func msBetween(_ start: UInt64, _ end: UInt64) -> Double? {
        guard start != 0, end != 0, end >= start else { return nil }
        return Double(end &- start) / 1_000_000.0
    }
}
