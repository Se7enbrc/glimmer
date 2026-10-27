// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

#if os(macOS)

// Per-frame stage timestamps share one bounded identity map. Singleton access is locked
// even when disabled; enabled producers update counters and append bounded typed records.
// JSON formatting and file writes run on the trace writer's background queue.

import Foundation
import os

// MARK: - Per-frame timing tracker

/// The map is lock-guarded; histogram stages and the trace writer synchronize their own state.
/// RTP timestamps correlate frames across decode and presentation; zero is untracked.
package typealias FrameInstrumentation = FrameTimingTracker

package final class FrameTimingTracker: @unchecked Sendable {

    /// The gate-checked singleton, installed by `start()` iff telemetry is on and
    /// cleared by `stop()`. `sharedBox` guards the slot: a per-frame read racing
    /// teardown's release of the previous tracker would be an ARC use-after-free.
    private static let sharedBox = OSAllocatedUnfairLock<FrameTimingTracker?>(initialState: nil)
    package static var shared: FrameTimingTracker? { sharedBox.withLock { $0 } }

    #if DEBUG
    package static func installForTesting(_ tracker: FrameTimingTracker?) {
        sharedBox.withLock { $0 = tracker }
    }
    #endif

    /// Install a fresh tracker iff the gate is on, and start its trace writer.
    /// Called from the exporter's `start()`. No-op (and nothing installed) when
    /// off; reading `shared` still takes the lifetime-protection lock.
    package static func startIfEnabled(sessionId: String, isoStamp: String,
                                       directory: URL, attemptID: UUID? = nil, diagnostic: Bool = false) {
        guard TelemetryGate.isEnabled else { return }
        let tracker = FrameTimingTracker(sessionId: sessionId, traceDirectory: directory,
                                         attemptID: attemptID, diagnostic: diagnostic)
        tracker.traceWriter.start(isoStamp: isoStamp)
        sharedBox.withLock { $0 = tracker }
    }

    /// Tear down + clear the singleton. Flushes + closes the trace writer.
    package static func stop() {
        let tracker = sharedBox.withLock { box -> FrameTimingTracker? in
            let previous = box
            box = nil
            return previous
        }
        tracker?.finishUnresolved(reason: .sessionEnd)
        tracker?.traceWriter.stop()
    }

    // ---- Instance state (only exists when enabled) ----

    package let histograms = LatencyHistograms()
    /// Callback-queue delay stays separate from the five-stage pipeline aggregate.
    package let inputTimingDropped = AtomicCounter()
    package let inputLatency = InputLatency()
    package let inputCallbackLatency = LatencyHistograms.Stage()
    package let inputLocalLatency = LatencyHistograms.Stage()
    /// CLIENT-SIDE input DELIVER latency: the pre-hop main-thread leg from the
    /// GameController valueChangedHandler entry to the batcher slot stamp (the
    /// deliver→enqueue age `inputLocalLatency` can't see - it starts at enqueue).
    /// Same self-locked Stage; observed off the present path. Measurement only.
    package let inputDeliverLatency = LatencyHistograms.Stage()
    /// RFI loss episodes: first loss detected → the frame that ended it, once per
    /// episode on the video receive thread (see VideoLossEpisode).
    package let rfiRecoveryMs = LatencyHistograms.Stage(bounds: LatencyHistograms.Stage.glassToGlassBoundsMs)

    /// Cadence at first processed packet, completed assembly and decoded callback entry.
    /// Receive timestamps are userspace processing observations, not kernel arrival times.
    /// Content gaps over one second are excluded from cadence histograms.
    package static let cadenceBoundsMs: [Double] = [
        1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 14, 16, 20, 25, 33, 50, 66, 132
    ]
    package let receiveCadence = LatencyHistograms.Stage(bounds: FrameTimingTracker.cadenceBoundsMs)
    package let assembleCadence = LatencyHistograms.Stage(bounds: FrameTimingTracker.cadenceBoundsMs)
    package let outputCadence = LatencyHistograms.Stage(bounds: FrameTimingTracker.cadenceBoundsMs)

    /// CRUISE forensics (units are counts/sec and gain multipliers, NOT ms -
    /// the Stage bucketing is unit-agnostic). Velocity distribution split MOVE
    /// vs DRAG, plus the applied gain per boosted batch, same split. The split
    /// is load-bearing: menu drag-pans and held-button aim (ADS/spray) share
    /// the drag path, so any drag-specific band tune (owner-reported slow menu
    /// drags) needs this distribution first.
    package static let cruiseVelocityBounds: [Double] = [
        250, 500, 750, 1000, 1250, 1500, 1750, 2000, 2250, 2500, 2750, 3000,
        3500, 4000, 5000, 7000, 10000
    ]
    package static let cruiseGainBounds: [Double] = [
        1.02, 1.1, 1.2, 1.3, 1.4, 1.5, 1.6, 1.7, 1.8, 1.9, 1.98, 2.0, 2.67, 4.0
    ]
    package let cruiseVelocityMove = LatencyHistograms.Stage(bounds: FrameTimingTracker.cruiseVelocityBounds)
    package let cruiseVelocityDrag = LatencyHistograms.Stage(bounds: FrameTimingTracker.cruiseVelocityBounds)
    package let cruiseGainMove = LatencyHistograms.Stage(bounds: FrameTimingTracker.cruiseGainBounds)
    package let cruiseGainDrag = LatencyHistograms.Stage(bounds: FrameTimingTracker.cruiseGainBounds)

    /// REORDER-DISPLACEMENT: how late reordered packets arrive, in ms and sequence
    /// slots (the rare out-of-order branch). Bounds cluster under the fixed 24ms hold
    /// and single-digit-ms Block-Ack releases; `_packets` bounds are counts.
    package static let reorderDispMsBounds: [Double] = [
        0.25, 0.5, 1, 1.5, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64, 96
    ]
    package static let reorderDispPacketBounds: [Double] = [
        1, 2, 3, 4, 6, 8, 12, 16, 24, 32, 48, 64
    ]
    package let reorderDisplacementMs = LatencyHistograms.Stage(bounds: FrameTimingTracker.reorderDispMsBounds)
    package let reorderDisplacementPackets = LatencyHistograms.Stage(bounds: FrameTimingTracker.reorderDispPacketBounds)

    /// Last-seen stage timestamps for the cadence deltas. Guarded by `mapLock`
    /// (stamped on the same calls that touch the in-flight map).
    private var lastReceiveNanos: UInt64 = 0
    private var lastAssembleNanos: UInt64 = 0
    private var lastOutputNanos: UInt64 = 0
    /// The PC's frame interval (ms): the last stats window's host_frame_interval_p50,
    /// published by the exporter so both series read one source. Guarded by `mapLock`.
    private var hostFrameIntervalP50Ms = 0.0
    /// Cadence deltas above this are a content gap (idle desktop, scene load),
    /// not delivery cadence - skipped so they can't pollute the histogram sum.
    private static let cadenceGapCutoffNanos: UInt64 = 1_000_000_000

    /// Both internal (not private): the trace renderer + drop-stub emitter in
    /// TelemetryLatency+Trace.swift are the only cross-file consumers.
    package let traceWriter: FrameTraceWriter
    package let sessionId: String

    /// One in-flight frame's stage timestamps (nanoseconds, monotonic uptime).
    /// receive + assemble are filled at `recordAssembled` (both are already
    /// captured upstream); submit/output/present fill as the frame advances.
    /// Module-internal so the drop-stub emitter (+Trace.swift) can read it.
    package struct Timing: Sendable {

        package init(
            frameIndex: Int32,
            receiveNanos: UInt64,
            assembleNanos: UInt64,
            frameBytes: Int32,
            isIDR: Bool,
            hostEncodeMs: Double,
            assembledHidden: Bool = false,
            submitNanos: UInt64 = 0,
            outputNanos: UInt64 = 0
        ) {
            self.frameIndex = frameIndex
            self.receiveNanos = receiveNanos
            self.assembleNanos = assembleNanos
            self.frameBytes = frameBytes
            self.isIDR = isIDR
            self.hostEncodeMs = hostEncodeMs
            self.assembledHidden = assembledHidden
            self.submitNanos = submitNanos
            self.outputNanos = outputNanos
        }

        package let frameIndex: Int32
        package let receiveNanos: UInt64
        package let assembleNanos: UInt64
        /// On-the-wire frame size (bytes) + keyframe flag, captured at assemble so
        /// the per-frame trace can carry size + IDR/P type - the signal that
        /// excludes / catches a big-frame or recurring-IDR spike on idle resume.
        package let frameBytes: Int32
        package let isIDR: Bool
        /// Host capture+encode latency for THIS frame (ms), from Sunshine's
        /// `frameHostProcessingLatency` (1/10 ms on the wire → ms here). 0 == the
        /// host didn't measure this frame (repeated frame / GFE), in which case
        /// glass-to-glass omits the host-encode leg rather than guessing. Captured
        /// at assemble (it rides the DecodeUnit) so glass-to-glass is per-frame.
        package let hostEncodeMs: Double
        /// Assembled while the window was suppressed or decode-gated: any later
        /// drop was designed, whatever the state when it is evicted.
        package var assembledHidden = false
        package var submitNanos: UInt64 = 0
        package var outputNanos: UInt64 = 0
        package var attemptID: String?
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
    func isWithinWarmup(presentNanos: UInt64) -> Bool {
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
    package var lastInputConsumedNanos: UInt64 = 0
    /// Client-side legs (deliver + queue→wire, ms) of the latest flushed input;
    /// rides `warmupLock` like the consume-once stamp it is read with.
    package var lastInputLegsMs = 0.0
    package func noteInputLegs(_ legsMs: Double) {
        os_unfair_lock_lock(warmupLock); lastInputLegsMs = legsMs; os_unfair_lock_unlock(warmupLock)
    }
    package func armResumePresentTag() {
        os_unfair_lock_lock(warmupLock); resumePresentPending = true; os_unfair_lock_unlock(warmupLock)
    }
    func takeResumePresentTag() -> Bool {
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
    private var attemptID: String?

    /// Map bound. ~256 in-flight frames is far beyond the real pipeline depth
    /// (decode backlog + pacer queue are each ~tens of frames), so a healthy
    /// stream never evicts; the bound exists purely so a frame that is received
    /// but never presented (dropped at decode or pacing) can't leak.
    private static let maxInFlight = 256
    private static let dropAgeNanos: UInt64 = 2_000_000_000

    /// Only an old leading run can be discarded without disturbing the order.
    package static func expiredDropCount(
        order: [UInt32],
        timings: [UInt32: Timing],
        nowNanos: UInt64
    ) -> Int {
        var count = 0
        for key in order {
            guard let assembled = timings[key]?.assembleNanos,
                  nowNanos >= assembled, nowNanos - assembled >= dropAgeNanos else { break }
            count += 1
        }
        return count
    }

    @discardableResult
    package func flushRemainingDrops(nowNanos: UInt64 = DispatchTime.now().uptimeNanoseconds) -> Int {
        os_unfair_lock_lock(mapLock)
        let expired = Self.expiredDropCount(order: insertionOrder, timings: inFlight,
                                            nowNanos: nowNanos)
        let keys = insertionOrder.prefix(expired)
        let remaining = keys.compactMap { key -> (rtp: UInt32, timing: Timing)? in
            guard let timing = inFlight.removeValue(forKey: key) else { return nil }
            return (key, timing)
        }
        insertionOrder.removeFirst(expired)
        os_unfair_lock_unlock(mapLock)
        if !remaining.isEmpty { emitDropStubs(remaining) }
        return remaining.count
    }

    /// Caller drains the previous transport and pacing producers before publishing the new attempt.
    package func beginAttempt(_ id: UUID) {
        finishUnresolved(reason: .attemptEnd, nextAttempt: id)
    }

    /// Session boundaries account every unresolved entry, including recent and intentionally hidden frames.
    @discardableResult
    package func finishUnresolved(reason: UnresolvedReason, nextAttempt: UUID? = nil) -> Int {
        os_unfair_lock_lock(mapLock)
        let remaining = insertionOrder.compactMap { key in inFlight[key].map { (key, $0) } }
        insertionOrder.removeAll(keepingCapacity: true)
        inFlight.removeAll(keepingCapacity: true)
        if let nextAttempt {
            attemptID = nextAttempt.uuidString
            lastReceiveNanos = 0
            lastAssembleNanos = 0
            lastOutputNanos = 0
        }
        os_unfair_lock_unlock(mapLock)
        if let nextAttempt { traceWriter.setAttempt(nextAttempt) }
        let stamp = now()
        for (rtp, timing) in remaining {
            traceWriter.appendStage(StageRecord(event: .unresolvedBoundary, rtpTimestamp: rtp,
                uptimeNanos: stamp, timing: timing, unresolvedReason: reason), sessionId: sessionId)
        }
        return remaining.count
    }

    package func attemptForFrame(rtpTimestamp: UInt32) -> String? {
        os_unfair_lock_lock(mapLock); defer { os_unfair_lock_unlock(mapLock) }
        return inFlight[rtpTimestamp]?.attemptID
    }

    /// Stage stamps (submit, output, present) read this uptime clock; tests script it and the counters.
    package let now: @Sendable () -> UInt64
    package let counters: TelemetryCounters

    /// Internal for tests; the engine only reaches a tracker through `shared`.
    package init(sessionId: String, traceDirectory: URL,
                 now: @escaping @Sendable () -> UInt64 = { DispatchTime.now().uptimeNanoseconds },
                 counters: TelemetryCounters = .shared, attemptID: UUID? = nil, diagnostic: Bool = false) {
        self.sessionId = sessionId
        self.now = now
        self.counters = counters
        self.attemptID = attemptID?.uuidString
        self.traceWriter = FrameTraceWriter(directory: traceDirectory, sessionId: sessionId,
                                            maxRetainedSegments: diagnostic ? 20 : FrameTraceWriter.maxTraceFiles,
                                            now: now)
        if let attemptID { traceWriter.setAttempt(attemptID) }
        mapLock.initialize(to: os_unfair_lock_s())
        warmupLock.initialize(to: os_unfair_lock_s())
    }
    deinit { mapLock.deallocate(); warmupLock.deallocate() }

    // MARK: Stage records (called from the existing hot-path call sites)

    /// First processed packet and completed access-unit times, already captured upstream.
    /// These userspace observations exclude kernel-to-read and earlier copy/decrypt work.
    @inlinable package func recordAssembled(rtpTimestamp: UInt32, frameIndex: Int32,
                                            receiveNanos: UInt64, assembleNanos: UInt64,
                                            frameBytes: Int32 = 0, isIDR: Bool = false,
                                            hostEncodeTenthsMs: UInt16 = 0) {
        guard rtpTimestamp != 0 else { return }
        var timing = Timing(frameIndex: frameIndex,
                            receiveNanos: receiveNanos,
                            assembleNanos: assembleNanos,
                            frameBytes: frameBytes,
                            isIDR: isIDR,
                            hostEncodeMs: Double(hostEncodeTenthsMs) / 10.0,
                            assembledHidden: counters.presentSuppressed || counters.decodeGated)
        os_unfair_lock_lock(mapLock)
        timing.attemptID = attemptID
        // Cadence deltas for the receive + assemble boundaries (clump
        // forensics). Captured under the map lock we already hold; observed
        // after unlock (the Stage has its own lock).
        let prevReceive = lastReceiveNanos
        let prevAssemble = lastAssembleNanos
        lastReceiveNanos = receiveNanos
        lastAssembleNanos = assembleNanos
        if inFlight[rtpTimestamp] == nil {
            insertionOrder.append(rtpTimestamp)
        }
        inFlight[rtpTimestamp] = timing
        // Bound the map: evict the stalest in-flight frame(s) - frames received
        // but dropped before present, which would otherwise leak. Evictions
        // become frames-file DROP STUBS, emitted off the lock (emitDropStubs).
        var evicted: [(rtp: UInt32, timing: Timing)] = []
        let expired = Self.expiredDropCount(order: insertionOrder, timings: inFlight,
                                            nowNanos: assembleNanos)
        for _ in 0..<expired {
            let stale = insertionOrder.removeFirst()
            if let dropped = inFlight.removeValue(forKey: stale) { evicted.append((stale, dropped)) }
        }
        while insertionOrder.count > Self.maxInFlight {
            let stale = insertionOrder.removeFirst()
            if let dropped = inFlight.removeValue(forKey: stale) { evicted.append((stale, dropped)) }
        }
        os_unfair_lock_unlock(mapLock)
        observeCadence(receiveCadence, prev: prevReceive, now: receiveNanos)
        observeCadence(assembleCadence, prev: prevAssemble, now: assembleNanos)
        if !evicted.isEmpty { emitDropStubs(evicted) }
    }

    /// Observe one inter-arrival delta into a cadence stage; skips the first
    /// event (no prev), out-of-order stamps, and content-gap deltas (> 1s).
    private func observeCadence(_ stage: LatencyHistograms.Stage, prev: UInt64, now: UInt64) {
        guard prev > 0, now > prev, now &- prev < Self.cadenceGapCutoffNanos else { return }
        stage.observe(Double(now &- prev) / 1_000_000.0)
    }

    /// The PC's frame interval (ms) input-to-photon waits half of; 0 until the first window.
    package var hostFrameIntervalMs: Double {
        get {
            os_unfair_lock_lock(mapLock); defer { os_unfair_lock_unlock(mapLock) }
            return hostFrameIntervalP50Ms
        }
        set {
            os_unfair_lock_lock(mapLock); defer { os_unfair_lock_unlock(mapLock) }
            hostFrameIntervalP50Ms = newValue
        }
    }

    /// Stamp before entering VideoToolbox; a callback may arrive before the call returns.
    @discardableResult
    package func recordSubmit(rtpTimestamp: UInt32) -> UInt64 {
        let stamp = now()
        guard rtpTimestamp != 0 else { return stamp }
        os_unfair_lock_lock(mapLock)
        if inFlight[rtpTimestamp] != nil { inFlight[rtpTimestamp]?.submitNanos = stamp }
        os_unfair_lock_unlock(mapLock)
        return stamp
    }

    /// Callback entry, before client bookkeeping. Completion timing survives a later pacer discard.
    package func recordOutput(rtpTimestamp: UInt32, uptimeNanos: UInt64? = nil,
                              status: Int32 = 0, flags: UInt32 = 0, decoded: Bool = true) {
        guard rtpTimestamp != 0 else { return }
        let stamp = uptimeNanos ?? now()
        os_unfair_lock_lock(mapLock)
        let previous = lastOutputNanos
        let duplicate = inFlight[rtpTimestamp]?.outputNanos != 0 && inFlight[rtpTimestamp] != nil
        if decoded, !duplicate {
            lastOutputNanos = max(previous, stamp)
            if inFlight[rtpTimestamp] != nil { inFlight[rtpTimestamp]?.outputNanos = stamp }
        }
        let timing = inFlight[rtpTimestamp]
        os_unfair_lock_unlock(mapLock)
        guard !duplicate else { return }
        if decoded {
            observeCadence(outputCadence, prev: previous, now: stamp)
            if let timing, !timing.assembledHidden, decodeWarmupFinished(at: stamp),
               let elapsed = msBetween(timing.submitNanos, stamp) {
                histograms.submitToOutput.observe(elapsed)
                if timing.isIDR { histograms.decodeIDR.observe(elapsed) } else { histograms.decodeP.observe(elapsed) }
            }
        }
        traceWriter.appendStage(StageRecord(event: .decodeOutput, rtpTimestamp: rtpTimestamp,
                                            uptimeNanos: stamp, timing: timing, status: status,
                                            flags: flags, decoded: decoded), sessionId: sessionId)
    }

    private func decodeWarmupFinished(at stamp: UInt64) -> Bool {
        os_unfair_lock_lock(warmupLock); defer { os_unfair_lock_unlock(warmupLock) }
        return firstPresentNanos > 0 && stamp >= firstPresentNanos
            && stamp - firstPresentNanos >= Self.warmupGraceNanos
    }

    /// Retirement is shared by enqueue and explicit discard, so expiry cannot report it twice.
    func takeTiming(rtpTimestamp: UInt32) -> Timing? {
        os_unfair_lock_lock(mapLock); defer { os_unfair_lock_unlock(mapLock) }
        guard let timing = inFlight.removeValue(forKey: rtpTimestamp) else { return nil }
        if let index = insertionOrder.firstIndex(of: rtpTimestamp) { insertionOrder.remove(at: index) }
        return timing
    }

    /// Record one IDR/RFI ROUND-TRIP observation (signal: IDR-RTT). Called from
    /// the depacketizer the instant a requested IDR/recovery frame is assembled,
    /// with the measured request→arrival delta (ms) the always-live
    /// `P2State.resolveIdrArrival` computed. Feeds the histogram + an explicit
    /// per-frame trace event line (distinct from the per-frame latency lines, via
    /// the `event` key) so a reader greps the exact recovery beat. Off the proven
    /// path - an IDR arrival is rare.
    @inlinable package func recordIdrRoundTrip(frameIndex: Int32, roundTripMs: Double) {
        guard roundTripMs.isFinite, roundTripMs >= 0 else { return }
        histograms.idrRoundTrip.observe(roundTripMs)
        traceWriter.append(
            "{\"session\":\"\(sessionId)\",\"event\":\"idr_round_trip\","
            + "\"frame\":\(frameIndex),\"idr_round_trip_ms\":\(TelemetryRenderer.jsonNumber(roundTripMs))}")
    }

    // The COMPOSITE stage computations (glass-to-glass + the consume-once
    // input-to-photon estimate) live in TelemetryLatency+Composites.swift -
    // topic split to keep this file under the length budget.

    /// Delta in milliseconds between two monotonic-nanosecond stamps, or nil if
    /// either is unset (0) or the delta is negative (clock skew / partial entry).
    func msBetween(_ start: UInt64, _ end: UInt64) -> Double? {
        guard start != 0, end != 0, end >= start else { return nil }
        return Double(end &- start) / 1_000_000.0
    }
}

#endif

#if !os(macOS)
// An uninhabited seam keeps shared input signatures stable without a recorder or storage.
package enum FrameInstrumentation: Sendable {
    @inlinable package static var shared: FrameInstrumentation? { nil }
    package enum RendererStatePhase: String, Sendable {
        case backpressureBegan = "backpressure_began"
        case backpressureEnded = "backpressure_ended"
        case flushBegan = "flush_began"
        case flushReturned = "flush_returned"
    }

    package enum RendererDecision: String, CaseIterable, Sendable {
        case frameRejectedFailed = "frame_rejected_failed"
        case frameRejectedNotReady = "frame_rejected_not_ready"
        case repaintRejectedFailed = "repaint_rejected_failed"
        case repaintRejectedNotReady = "repaint_rejected_not_ready"
        case repaintCopyFailed = "repaint_copy_failed"
        case repaintEnqueued = "repaint_enqueued"
    }

    package enum PacerDiscardReason: String, Sendable {
        case overflow, suppressed, trim, backoff, stopped, rebind, cleared, recovery
    }
}
#endif
