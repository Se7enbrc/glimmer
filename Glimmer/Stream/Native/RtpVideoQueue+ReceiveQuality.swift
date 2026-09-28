// Receive-thread quality accounting uses fixed storage: no allocation or clock
// read on the steady path. Only rare gaps and excessive reorder pay locked telemetry.

import Foundation

extension RtpVideoQueue {
    func accumulateReceiveQuality(seq: UInt16, frameIndex: UInt32, receiveTimeUs: UInt64) {
        observeArrival(receiveTimeUs, seq: seq)
        guard haveSeqBaseline else {
            seedSequence(seq, frameIndex: frameIndex)
            return
        }
        let newerFrame = Self.isBefore32(seqNewestFrame, frameIndex)
        // A stale arrival must neither consume blackout eligibility nor reset history.
        // New frame progress also disambiguates a fresh sequence still in the ring.
        if sequenceBlackoutEligible, newerFrame,
           seq == seqHighestSeen || Self.isBefore16(seq, seqHighestSeen) {
            seedSequence(seq, frameIndex: frameIndex)
            return
        }
        if hasRecentSequence(seq) || seq == seqHighestSeen {
            windowDuplicate += 1
            return
        }
        // Older frames can alias forward in sequence space after a blackout.
        if !Self.isBefore32(frameIndex, seqNewestFrame), !Self.isBefore16(seq, seqHighestSeen) {
            let jump = Int(Self.u16(Int(seq) - Int(seqHighestSeen)))
            if jump > 1 {
                windowLostPreFec += jump - 1
                gapOpenLowSeq = seqHighestSeen &+ 1
                gapOpenHighSeq = seq &- 1
                gapOpenAtUs = receiveTimeUs
                haveOpenGap = true
            }
            seqHighestSeen = seq
            sequenceBlackoutEligible = false
        } else {
            windowOutOfOrder += 1
            // A late filler can straddle a reporting boundary. Bound parked credits
            // so old reorders cannot suppress an arbitrarily large future loss.
            if windowLostPreFec > 0 {
                windowLostPreFec -= 1
            } else if pendingReorderCredit < Self.maxPendingReorderCredit {
                pendingReorderCredit += 1
            }
            recordReorderDisplacement(seq: seq, receiveTimeUs: receiveTimeUs)
        }
        if newerFrame { seqNewestFrame = frameIndex }
        rememberSeq(seq)
    }

    private func observeArrival(_ receiveTimeUs: UInt64, seq: UInt16) {
        if haveLastArrival, receiveTimeUs >= lastArrivalUs {
            let gapUs = receiveTimeUs &- lastArrivalUs
            if gapUs > 1_000_000 { sequenceBlackoutEligible = true }
            observeGap(Double(gapUs))
            if haveSeqBaseline, gapUs > Self.gapEventThresholdUs {
                TelemetryExporter.recordLiveEvent(Self.gapEventFields(
                    gapUs: gapUs, atUs: receiveTimeUs, lastSeq: seqHighestSeen, nextSeq: seq))
            }
        }
        lastArrivalUs = receiveTimeUs
        haveLastArrival = true
    }

    /// A video arrival gap past this (µs) gets its own `video_gap` event, so a host
    /// stall, a link blackout and wire loss each have a row to join by t_ns.
    static let gapEventThresholdUs: UInt64 = 100_000

    /// The `video_gap` row: the gap, the arrival that ended it (monotonic ns) and
    /// the RTP sequence numbers either side.
    static func gapEventFields(gapUs: UInt64, atUs: UInt64, lastSeq: UInt16, nextSeq: UInt16) -> [String] {
        [
            "\"event\":\"video_gap\"",
            "\"t_ns\":\(atUs &* 1_000)",
            "\"gap_ms\":" + TelemetryRenderer.jsonNumber(Double(gapUs) / 1_000),
            "\"last_seq\":\(lastSeq)",
            "\"next_seq\":\(nextSeq)"
        ]
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

    func hasRecentSequence(_ seq: UInt16) -> Bool {
        recentSeqBits[Int(seq) >> 6] & (UInt64(1) << (Int(seq) & 63)) != 0
    }

    /// Evict in constant time without shifting storage or hashing on every packet.
    func rememberSeq(_ seq: UInt16) {
        guard !hasRecentSequence(seq) else { return }
        if recentSeqCount == Self.recentSeqCapacity {
            let evicted = Int(recentSeqOrder[recentSeqHead])
            recentSeqBits[evicted >> 6] &= ~(UInt64(1) << (evicted & 63))
        } else {
            recentSeqCount += 1
        }
        recentSeqOrder[recentSeqHead] = seq
        recentSeqHead = (recentSeqHead + 1) & (Self.recentSeqCapacity - 1)
        recentSeqBits[Int(seq) >> 6] |= UInt64(1) << (Int(seq) & 63)
    }

    private func seedSequence(_ seq: UInt16, frameIndex: UInt32) {
        for index in recentSeqBits.indices { recentSeqBits[index] = 0 }
        recentSeqCount = 0
        recentSeqHead = 0
        seqHighestSeen = seq
        seqNewestFrame = frameIndex
        haveSeqBaseline = true
        haveOpenGap = false
        pendingReorderCredit = 0
        sequenceBlackoutEligible = false
        rememberSeq(seq)
    }

    /// Bucket one inter-arrival gap (µs) into the log-spaced histogram + track the
    /// running max. Branchless-ish ascending find; integer bumps only.
    func observeGap(_ gapUs: Double) {
        guard gapUs.isFinite, gapUs >= 0 else { return }
        if gapUs > gapMaxUs { gapMaxUs = gapUs }
        // GAP-EVENT counters (20/50/100ms, cumulative - a 100ms gap counts in all
        // three). The histogram below is windowed: flushed and DISCARDED every ~2s,
        // and its p95 is structurally blind to a rare blip (one 100ms gap is
        // 1/10200 of window samples at ~5,100 pkts/s), so only the gauge-
        // overwritten max ever saw one - and a max can't COUNT. These go straight
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

    /// Estimate a quantile (0...1) from the cumulative gap histogram via linear
    /// interpolation within the matching bucket - the same model the latency rig
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
