// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Bound decode admission and retire reservations by their owning epoch.

import Foundation
import VideoToolbox
import os

extension VideoDecoder {

    struct DecodeReservations {
        var queued = 0
        var submitted = 0
        var total: Int { queued + submitted }
    }

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

    /// Absorb bursts within the existing ceiling while VT drains; stalled work recovers through an IDR.
    /// Superseded queued payloads must be released with their reservations, even if decodeQueue is blocked.
    /// Receive, decode and output callbacks share the reservation lock.
    nonisolated func reserveDecodeSlot(isIDR: Bool, epoch: UInt = 0) -> DecodeSlotDecision {
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
            pendingDecodes.removeAll(keepingCapacity: true)
            pendingDecodeTimingReset = true
            decodeReservations.removeAll(keepingCapacity: true)
            decodeReservations[epoch] = DecodeReservations(queued: 1)
            latestReservedEpoch = epoch
            inFlightDecodes = 1
            consecutiveBacklogOverflow = 0
            lastVtDecodeFailed = false
            inFlightDecodeLock.unlock()
            scheduleDecodeDrain()
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
            decodeReservations[epoch, default: DecodeReservations()].queued += 1
            latestReservedEpoch = epoch
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
            decodeReservations[epoch, default: DecodeReservations()].queued += 1
            latestReservedEpoch = epoch
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

    /// Move a live queued reservation into VT ownership; superseded work never reaches VT.
    nonisolated func beginSubmittedDecode(epoch: UInt) -> Bool {
        inFlightDecodeLock.lock(); defer { inFlightDecodeLock.unlock() }
        guard var slots = decodeReservations[epoch], slots.queued > 0 else { return false }
        slots.queued -= 1
        slots.submitted += 1
        decodeReservations[epoch] = slots
        return true
    }

    nonisolated func hasQueuedDecode(epoch: UInt) -> Bool {
        inFlightDecodeLock.lock(); defer { inFlightDecodeLock.unlock() }
        return (decodeReservations[epoch]?.queued ?? 0) > 0
    }

    /// Retire only the owning epoch and phase; callbacks from abandoned sessions cannot
    /// consume a replacement frame's slot or overwrite its failure verdict.
    @discardableResult
    nonisolated func releaseInFlightDecode(epoch: UInt = 0, submitted: Bool = false,
                                           vtFailed: Bool? = nil) -> Bool {
        inFlightDecodeLock.lock(); defer { inFlightDecodeLock.unlock() }
        guard var slots = decodeReservations[epoch] else { return false }
        if submitted {
            guard slots.submitted > 0 else { return false }
            slots.submitted -= 1
        } else {
            guard slots.queued > 0 else { return false }
            slots.queued -= 1
        }
        inFlightDecodes -= 1
        if slots.total == 0 { decodeReservations.removeValue(forKey: epoch) } else { decodeReservations[epoch] = slots }
        if let vtFailed, epoch == latestReservedEpoch { lastVtDecodeFailed = vtFailed }
        return true
    }

    /// Invalidation abandons VT-owned slots, while later work already queued for decode survives.
    nonisolated func retireInvalidatedDecodes() {
        inFlightDecodeLock.lock()
        for (epoch, var slots) in decodeReservations {
            inFlightDecodes -= slots.submitted
            slots.submitted = 0
            if slots.total == 0 { decodeReservations.removeValue(forKey: epoch) } else { decodeReservations[epoch] = slots }
        }
        inFlightDecodeLock.unlock()
        statsCollector.dropPendingDecodeSubmits()
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
