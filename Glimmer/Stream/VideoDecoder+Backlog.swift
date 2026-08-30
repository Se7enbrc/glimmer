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
        inFlightDecodeLock.lock()
        let backlog = inFlightDecodes

        // Common case: under the nominal bound. Reserve and clear any streak.
        if backlog < maxInFlightDecodes {
            inFlightDecodes += 1
            consecutiveBacklogOverflow = 0
            inFlightDecodeLock.unlock()
            return .reserved
        }

        // At/over the nominal bound - a burst is building. Decide absorb vs
        // flush. `secondsSinceLastDecodedFrame()` is the VT-draining signal: it
        // advances on every VT output callback, so a small value means VT is
        // actively retiring frames (a transient burst it will drain), while a
        // value past the stall window means VT has genuinely stopped producing.
        let vtDark = secondsSinceLastDecodedFrame()
        let vtDraining = vtDark < VideoDecoder.decodeStallWindowSeconds
        let underCeiling = backlog < maxInFlightDecodeCeiling
        consecutiveBacklogOverflow += 1

        // Absorb the burst while VT is draining and we're under the hard ceiling.
        if vtDraining, underCeiling {
            inFlightDecodes += 1
            let depth = inFlightDecodes
            inFlightDecodeLock.unlock()
            OSSignposter.decode.emitEvent(
                "BacklogBurstAbsorbed", "depth=\(depth, privacy: .public)")
            return .reserved
        }

        // STALL ESCALATION - see `DecodeSlotDecision.reservedForStallRecreate`.
        // An IDR during a stall SUSTAINED past the escalation window is the
        // cure, not another casualty: abandon the wedged session's slots (the
        // `handleCleanup` reset discipline; `releaseInFlightDecode` floors at
        // 0, so a late callback from the doomed session cannot underflow -
        // worst case it eats this IDR's slot early, briefly loosening a
        // protective bound) and reserve this frame to drive a FORCED session
        // recreate. The window is well past `decodeStallWindowSeconds`, so a
        // burst VT is merely slow to drain never triggers a recreate - only a
        // VT that has produced nothing across many IDR round-trips.
        if isIDR, vtDark >= VideoDecoder.decodeStallEscalateSeconds {
            inFlightDecodes = 1
            consecutiveBacklogOverflow = 0
            inFlightDecodeLock.unlock()
            log.error(
                // swiftlint:disable:next line_length
                "Decode stall ESCALATION (\(backlog) in flight, VT dark \(String(format: "%.1f", vtDark))s) - abandoning wedged session, forcing recreate with this IDR")
            Diag.error("Video decode stalled \(String(format: "%.1f", vtDark))s with "
                + "\(backlog) frames wedged in VT - rebuilding the decode session in "
                + "place with the arriving IDR", "Stream")
            OSSignposter.decode.emitEvent(
                "DecodeStallRecreate", "backlog=\(backlog, privacy: .public)")
            return .reservedForStallRecreate
        }

        // Genuine sustained stall (VT not draining, or hit the ceiling). Drop +
        // flush-to-IDR. `streak` is how many assembled frames sat in the overflow
        // zone before this escalation - large means a long burst, small means VT
        // hard-stopped immediately.
        let streak = consecutiveBacklogOverflow
        consecutiveBacklogOverflow = 0
        inFlightDecodeLock.unlock()
        log.warning(
            // swiftlint:disable:next line_length
            "Decode backlog stall (\(backlog) in flight, overflowStreak=\(streak), vtDraining=\(vtDraining)) - dropping frame, flushing to next IDR")
        OSSignposter.decode.emitEvent("IDRRequested", "trigger=decode_backlog_stall")
        return .dropAndFlush
    }

    /// Decrement the in-flight-decode backlog counter by one. Called exactly
    /// once per reserved frame: from the VT output callback when VT retires an
    /// accepted frame, or from an abandon path when the frame never reaches (or
    /// is rejected by) VT. Lock-guarded because the increment happens on the
    /// receive thread / decode queue while the success-path decrement happens on
    /// VT's internal output-callback thread.
    nonisolated func releaseInFlightDecode() {
        inFlightDecodeLock.lock()
        if inFlightDecodes > 0 { inFlightDecodes -= 1 }
        inFlightDecodeLock.unlock()
    }
}
