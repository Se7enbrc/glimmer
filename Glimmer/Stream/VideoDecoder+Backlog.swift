//
//  VideoDecoder+Backlog.swift
//
//  The in-flight decode backlog gate: the two artifact-safe reservation outcomes
//  (`DecodeSlotDecision`), the burst-absorbing reserve with its sustained-stall
//  and stall-escalation verdicts, and the matching release the VT output callback
//  and every abandon path call. Split out of VideoDecoder+Decode.swift to keep
//  each unit focused; see VideoDecoder.swift for the counter and its lock.
//

import Foundation
import VideoToolbox
import os

extension VideoDecoder {

    /// Outcome of a backlog reservation. Only two artifact-safe outcomes exist
    /// (see `decodeAssembledFrame`): reserve + decode, or drop + flush-to-IDR.
    /// There is deliberately no silent-drop case - a sink-side drop without a
    /// flush would orphan the reference chain the depacketizer believes is
    /// intact.
    enum DecodeSlotDecision {
        /// A slot was reserved; proceed to dispatch the decode. Balanced by a
        /// later `releaseInFlightDecode`.
        case reserved
        /// The backlog is genuinely stalled (at the hard ceiling, or full while
        /// VT has produced no output for the stall window). Drop this frame and
        /// flush-to-IDR. No slot was reserved.
        case dropAndFlush
        /// STALL ESCALATION (wedge audit 2026-08-17): an IDR arrived while the
        /// stall has persisted past `decodeStallEscalateSeconds` - the wedged
        /// session's in-flight slots were abandoned (counter reset to this
        /// IDR's own slot, the `handleCleanup` discipline) and the caller must
        /// FORCE a session recreate with this frame. Without this case the
        /// gate starved its own cure: every `.dropAndFlush` requests an IDR,
        /// and the gate then dropped that IDR too - the recovery whose param
        /// rebuild is the only mechanism that can replace a hosed VT session -
        /// in a closed loop, forever, while ENet keepalives kept the frame
        /// watchdog's teardown on hold (received, assembled, dropped, for
        /// hours: the video twin of the 2026-08-12 audio wedge).
        case reservedForStallRecreate
    }

    // Internal (not private) so `decodeAssembledFrame` in
    // VideoDecoder+Decode.swift can call across the split.
    /// Reserve one in-flight-decode slot for a frame about to be dispatched, or
    /// decide to drop-and-flush when the backlog is genuinely stalled.
    ///
    /// Burst absorption vs sustained-stall escalation:
    ///   * backlog < `maxInFlightDecodes` → reserve normally; reset the overflow
    ///     streak (the backlog drained back under the bound).
    ///   * `maxInFlightDecodes` ≤ backlog < `maxInFlightDecodeCeiling` AND VT is
    ///     ACTIVELY DRAINING (it produced output within the last
    ///     `decodeStallWindowSeconds`) → ABSORB: reserve anyway so the VPN burst
    ///     rides VT's pipeline instead of flushing-to-IDR. A transient burst is
    ///     never flushed, no matter how deep, as long as VT keeps retiring frames
    ///     - that's the whole point of the deep bound.
    ///   * VT has produced NO output for the stall window (genuine VT stall) OR
    ///     backlog ≥ `maxInFlightDecodeCeiling` (memory/latency ceiling even with
    ///     absorption) → `.dropAndFlush`.
    ///   * an IDR after `decodeStallEscalateSeconds` of VT darkness, with a full
    ///     backlog or VT's last verdict a failure → `.reservedForStallRecreate`.
    /// The VT-output clock (`secondsSinceLastDecodedFrame`) is the principled
    /// gate: it cleanly separates "transient burst VT is working through" from
    /// "VT genuinely stopped." `consecutiveBacklogOverflow` is tracked only for
    /// the diagnostic log (how long the burst has sat in the overflow zone), not
    /// as a flush trigger - flushing a deep-but-draining burst would defeat the
    /// bound bump and reintroduce the hitch.
    ///
    /// The matching decrement is `releaseInFlightDecode`, called when VT retires
    /// the frame (output callback) or on any abandon path. Lock-guarded because
    /// the count is read/written from both the receive thread (reserve) and the
    /// decode queue / VT output-callback thread (release).
    nonisolated func reserveDecodeSlot(isIDR: Bool) -> DecodeSlotDecision {
        // The VT-draining signal: it advances on every decoded output, so a
        // small value means VT is retiring frames. Floored at the gate-lift
        // edge so a long hidden span never reads as a wedge.
        let vtDark = min(secondsSinceLastDecodedFrame(), secondsSinceDecodeGateLifted())
        inFlightDecodeLock.lock()
        let backlog = inFlightDecodes
        let overBound = backlog >= maxInFlightDecodes

        // STALL ESCALATION (see `.reservedForStallRecreate`): an IDR after VT has
        // produced nothing for the escalation window, with a full backlog or VT's
        // own failure verdict (a dead session frees every slot), recreates it.
        if isIDR, overBound || lastVtDecodeFailed,
           vtDark >= VideoDecoder.decodeStallEscalateSeconds {
            inFlightDecodes = 1
            consecutiveBacklogOverflow = 0
            lastVtDecodeFailed = false
            inFlightDecodeLock.unlock()
            // Older submits finish first; drain their stamps before this IDR's decode block.
            decodeQueue.async { [statsCollector] in
                statsCollector.dropPendingDecodeSubmits()
            }
            log.error("""
                Decode stall ESCALATION (\(backlog) in flight, VT dark \(String(format: "%.1f", vtDark))s) - abandoning wedged \
                session, forcing recreate with this IDR
                """)
            Diag.error("Video decode produced nothing for \(String(format: "%.1f", vtDark))s "
                + "(\(backlog) frames in flight) - rebuilding the decode session in "
                + "place with the arriving IDR", "Stream")
            OSSignposter.decode.emitEvent(
                "DecodeStallRecreate", "backlog=\(backlog, privacy: .public)")
            return .reservedForStallRecreate
        }

        // Common case: under the nominal bound. Reserve and clear any streak.
        if !overBound {
            inFlightDecodes += 1
            consecutiveBacklogOverflow = 0
            inFlightDecodeLock.unlock()
            return .reserved
        }

        // At/over the nominal bound - a burst is building. Absorb it while VT
        // is draining and we're under the hard ceiling; otherwise VT has
        // genuinely stopped producing.
        let vtDraining = vtDark < VideoDecoder.decodeStallWindowSeconds
        let underCeiling = backlog < maxInFlightDecodeCeiling
        consecutiveBacklogOverflow += 1

        if vtDraining, underCeiling {
            inFlightDecodes += 1
            let depth = inFlightDecodes
            inFlightDecodeLock.unlock()
            OSSignposter.decode.emitEvent(
                "BacklogBurstAbsorbed", "depth=\(depth, privacy: .public)")
            return .reserved
        }

        // Genuine sustained stall (VT not draining, or hit the ceiling). Drop +
        // flush-to-IDR. `streak` is how many assembled frames sat in the overflow
        // zone before this escalation - large means a long burst, small means VT
        // hard-stopped immediately.
        let streak = consecutiveBacklogOverflow
        consecutiveBacklogOverflow = 0
        inFlightDecodeLock.unlock()
        log.warning("""
            Decode backlog stall (\(backlog) in flight, overflowStreak=\(streak), vtDraining=\(vtDraining)) - dropping frame, \
            flushing to next IDR
            """)
        OSSignposter.decode.emitEvent("IDRRequested", "trigger=decode_backlog_stall")
        return .dropAndFlush
    }

    /// Retire one reserved frame (VT output callback or an abandon path), flooring
    /// at 0 so a late callback from a session the escalation abandoned can't
    /// underflow. `vtFailed` records VT's verdict when this retire carries one.
    nonisolated func releaseInFlightDecode(vtFailed: Bool? = nil) {
        inFlightDecodeLock.lock()
        if inFlightDecodes > 0 { inFlightDecodes -= 1 }
        if let vtFailed { lastVtDecodeFailed = vtFailed }
        inFlightDecodeLock.unlock()
    }

    /// VT failed a frame fed under `epoch` (callback error, no image, or an
    /// inline reject): arm the resync so the next non-IDR frame flushes the
    /// depacketizer to wait-for-IDR. Moot once stopped (teardown flushes VT).
    nonisolated func noteVtDecodeFailure(epoch: UInt, status: OSStatus) {
        guard isStreaming, armResyncAfterDecodeError(epoch: epoch) else { return }
        log.error("VideoToolbox decode failed (status \(status)) - resyncing to the next IDR")
        Diag.warn("Video decode failed (VideoToolbox status \(status)) - resyncing to the next keyframe",
                  "Stream")
        OSSignposter.decode.emitEvent("IDRRequested", "trigger=vt_decode_failed")
    }
}
