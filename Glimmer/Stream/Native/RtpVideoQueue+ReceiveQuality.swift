//
//  RtpVideoQueue+ReceiveQuality.swift
//
//  P1 NETWORK receive-quality + inter-packet-gap accumulation for the opt-in
//  telemetry rig, split out of RtpVideoQueue.swift to keep that type's body under
//  the SwiftLint limit. Everything here is derived PURELY from the RTP sequence
//  numbers + arrival times of packets WE receive (no host tool): pre-FEC loss,
//  out-of-order, and duplicate classification, plus a log-spaced inter-arrival-gap
//  histogram (the microburst detector). The window tallies live on RtpVideoQueue
//  (extensions can't hold stored state) and are flushed into the always-live
//  TelemetryCounters in maybeLogMetrics; see RtpVideoQueue.swift for those fields.
//
//  HOT-PATH SAFETY: these run on the single receive thread per non-replay
//  datagram, off the receiveTimeUs the jitter path already reads — pure integer
//  compares + a histogram bump, no lock, no alloc, no extra clock read. The one
//  exception is deliberate: the 20/50/100ms GAP-EVENT counters in observeGap pay
//  a locked add, but only on a >20ms inter-arrival gap — i.e. only after the
//  path just sat idle for 20ms+, where a sub-µs add is noise. The always-live
//  counters they feed are only ever READ by the exporter when telemetry is
//  opt-in ON (default OFF), so a normal stream pays only the integer work and
//  nothing reads the result.
//

import Foundation

extension RtpVideoQueue {

    /// P1 NETWORK per-datagram receive-quality + inter-packet-gap accumulation.
    /// Pure integer work off the RTP seq and the arrival time the jitter path
    /// already has — no lock, no alloc, no extra clock read — so it adds nothing
    /// measurable to the multi-kHz receive path. Classifies each datagram:
    ///   * FORWARD (seq advances the highest seen): the normal case. The forward
    ///     jump beyond +1 is pre-FEC LOSS (a gap in the wire sequence space).
    ///   * BEHIND highest, seq already in the recent ring: a true DUPLICATE.
    ///   * BEHIND highest, not in the ring: a genuine OUT-OF-ORDER (reorder).
    /// All wrap-aware via the existing isBefore16 helper. The gap histogram buckets
    /// the inter-arrival µs gap for the microburst detector.
    func accumulateReceiveQuality(seq: UInt16, receiveTimeUs: UInt64) {
        // Inter-packet gap (µs) — the microburst detector. First packet seeds it.
        if haveLastArrival, receiveTimeUs >= lastArrivalUs {
            observeGap(Double(receiveTimeUs &- lastArrivalUs))
        }
        lastArrivalUs = receiveTimeUs
        haveLastArrival = true

        guard haveSeqBaseline else {
            // Seed the sequence space on the first datagram; none lost yet.
            // recentSeqs tracks it so an immediate dup is caught.
            seqHighestSeen = seq
            haveSeqBaseline = true
            rememberSeq(seq)
            return
        }

        if seq == seqHighestSeen || !Self.isBefore16(seq, seqHighestSeen) {
            // At or ahead of the highest seen → a forward-progress packet.
            if seq == seqHighestSeen || recentSeqs.contains(seq) {
                // Same seq as the highest (or a re-seen one at the front) → dup.
                windowDuplicate += 1
            } else {
                // Forward jump: the gap beyond +1 is pre-FEC loss.
                let jump = Int(Self.u16(Int(seq) - Int(seqHighestSeen)))
                if jump > 1 { windowLostPreFec += (jump - 1) }
                seqHighestSeen = seq
                rememberSeq(seq)
            }
        } else {
            // Behind the highest seen: duplicate if we've already seen this exact
            // seq, otherwise a genuine reorder. Either way it is NOT a new expected
            // packet (it filled a gap we already counted as expected, or repeated
            // one), so the loss accounting below keeps the pre-FEC loss rate an
            // honest gap/expected ratio.
            if recentSeqs.contains(seq) {
                windowDuplicate += 1
            } else {
                windowOutOfOrder += 1
                // A reordered packet that fills a previously-counted gap recovers
                // one "lost" slot — uncount it so a pure reorder (no real loss)
                // doesn't read as loss. The gap was counted as a forward jump; if it
                // happened in THIS window we credit it straight away. But the gap and
                // its late filler often straddle a maybeLogMetrics boundary, so when
                // there's nothing left to deduct this window, PARK the credit and
                // apply it against a later window's loss before it flushes (see
                // applyPendingReorderCredit). This stops a pure reorder reading as
                // permanent loss across the window boundary.
                if windowLostPreFec > 0 {
                    windowLostPreFec -= 1
                } else if pendingReorderCredit < Self.maxPendingReorderCredit {
                    // Cap the parked credit: it legitimately straddles ONE window
                    // boundary, so a credit that never finds a future loss to cancel
                    // is stale and must not be allowed to suppress a genuine loss
                    // spike arbitrarily far in the future.
                    pendingReorderCredit += 1
                }
                rememberSeq(seq)
            }
        }
    }

    /// Apply any parked cross-window reorder credit against this window's pre-FEC
    /// loss just before it is flushed, so a reorder whose gap was counted in an
    /// EARLIER window (or whose late filler lands in a LATER window) still cancels
    /// the loss it recovered instead of double-counting as permanent loss. Returns
    /// the corrected (clamped ≥ 0) loss to fold into the total; leftover credit
    /// stays parked for a future window's loss. Called from maybeLogMetrics under
    /// the same single-receive-thread isolation as the accumulators.
    func applyPendingReorderCredit() -> Int {
        guard pendingReorderCredit > 0, windowLostPreFec > 0 else {
            return max(0, windowLostPreFec)
        }
        let applied = min(pendingReorderCredit, windowLostPreFec)
        windowLostPreFec -= applied
        pendingReorderCredit -= applied
        return max(0, windowLostPreFec)
    }

    /// Add a seq to the bounded recent-seq ring (dup detection). FIFO-evicts the
    /// oldest past the cap so the set can't grow; cleared per window in
    /// maybeLogMetrics so it tracks only the current window's reorder/dup horizon.
    func rememberSeq(_ seq: UInt16) {
        if recentSeqs.insert(seq).inserted {
            recentSeqOrder.append(seq)
            if recentSeqOrder.count > Self.recentSeqCapacity {
                let evicted = recentSeqOrder.removeFirst()
                recentSeqs.remove(evicted)
            }
        }
    }

    /// Bucket one inter-arrival gap (µs) into the log-spaced histogram + track the
    /// running max. Branchless-ish ascending find; integer bumps only.
    func observeGap(_ gapUs: Double) {
        guard gapUs.isFinite, gapUs >= 0 else { return }
        if gapUs > gapMaxUs { gapMaxUs = gapUs }
        // GAP-EVENT counters (20/50/100ms, cumulative — a 100ms gap counts in all
        // three). The histogram below is windowed: flushed and DISCARDED every ~2s,
        // and its p95 is structurally blind to a rare blip (one 100ms gap is
        // 1/10200 of window samples at ~5,100 pkts/s), so only the gauge-
        // overwritten max ever saw one — and a max can't COUNT. These go straight
        // into the always-live per-socket totals at the crossing instant: a >20ms
        // gap means the receive path just sat idle that long, so the counter's
        // sub-µs locked add amortizes into dead air already paid; the steady
        // sub-threshold case adds exactly one compare.
        if gapUs > 20_000 {
            let counters = TelemetryCounters.shared
            counters.videoGapOver20msTotal.increment()
            if gapUs > 50_000 { counters.videoGapOver50msTotal.increment() }
            if gapUs > 100_000 { counters.videoGapOver100msTotal.increment() }
        }
        var index = 0
        let bounds = Self.gapBoundsUs
        while index < bounds.count {
            if gapUs <= bounds[index] { break }
            index += 1
        }
        gapBuckets[index] += 1
        gapCount += 1
    }

    /// Estimate a quantile (0…1) from the cumulative gap histogram via linear
    /// interpolation within the matching bucket — the same model the latency rig
    /// uses. Returns 0 when no gaps recorded. Used to publish p50/p95 each window.
    func gapQuantile(_ quantile: Double) -> Double {
        guard gapCount > 0 else { return 0 }
        let rank = quantile * Double(gapCount)
        var cumulative = 0.0
        let bounds = Self.gapBoundsUs
        for index in 0..<bounds.count {
            let bucket = Double(gapBuckets[index])
            cumulative += bucket
            if cumulative >= rank {
                let bucketLow = index == 0 ? 0.0 : bounds[index - 1]
                let priorCumulative = cumulative - bucket
                let frac = bucket > 0 ? (rank - priorCumulative) / bucket : 0
                return bucketLow + (bounds[index] - bucketLow) * frac
            }
        }
        // In the implicit top bucket: clamp to the running max (no upper edge).
        return gapMaxUs
    }
}
