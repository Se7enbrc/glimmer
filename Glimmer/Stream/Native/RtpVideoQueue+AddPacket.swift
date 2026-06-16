//
//  RtpVideoQueue+AddPacket.swift
//
//  The RtpvAddPacket reassembly half of the RTP video queue state machine, split
//  out of RtpVideoQueue.swift to keep each file under the SwiftLint length limit.
//  Ports RtpVideoQueue.c RtpvAddPacket: window/duplicate rejection, the bounded
//  cross-frame reorder hold (Issue 2b), the new-frame / new-FEC-block transition
//  (unrecoverable-frame reporting + drop, then per-frame buffer-window reset), the
//  per-packet missing/received counting, and queuePacket (the duplicate/out-of-
//  sequence detector that latches receivedOosData).
//
//  These run on the SAME single receive thread as the parse entry point and the
//  reconstruct half (RtpVideoQueue.swift / RtpVideoQueue+Reconstruct.swift) - the
//  split is purely textual (a Swift extension can only reach non-private members,
//  which is why the queue's touched state is `internal` rather than `private`; see
//  the visibility note atop RtpVideoQueue.swift). No isolation, ordering, locking,
//  or behavioral contract changes.
//

import Foundation

extension RtpVideoQueue {

    // MARK: - RtpvAddPacket (RtpVideoQueue.c:543-804)

    /// The decoded NV-header fields a single datagram contributes to the add path,
    /// parsed once at the top of `addPacket` and threaded through its helpers.
    private struct NvFields {
        let frameIndex: UInt32
        let fecIndex: UInt32
        let fecCurrentBlockNumber: UInt8
        let multiFecBlocks: UInt8
        let fecInfo: UInt32
    }

    /// Outcome of the new-frame / new-FEC-block transition handling: whether the
    /// caller should keep going with the just-validated buffer window, or return
    /// early with a terminal `AddResult` (a reorder-hold `.queued`, or a dropped-
    /// frame `.rejected`).
    private enum TransitionOutcome {
        case proceed
        case finished(AddResult)
    }

    func addPacket(_ rtp: ParsedRtp, receiveTimeUs: UInt64,
                   allowHold: Bool = true) -> AddResult {
        let bytes = rtp.bytes
        let seq = rtp.seq
        let timestamp = rtp.timestamp

        // Reject packets behind our current buffer window.
        if Self.isBefore16(seq, nextContiguousSequenceNumber) {
            return .rejected
        }

        // Reject packets too small for the NV header.
        if rtp.length < rtp.dataOffset + 16 {
            return .rejected
        }

        // Issue 2b: return to the strict (no-hold) regime once the link has run
        // clean for the cooldown period since the last out-of-order observation
        // (mirrors moonlight's 5-min SPECULATIVE_RFI_COOLDOWN hysteresis). Uses
        // presentation time (90kHz → µs) so it tracks media time, like the C.
        //
        // ORDINARY comparison, matching upstream RtpVideoQueue.c exactly
        // (`presentationTimeUs > lastOos + COOLDOWN`): presentationUs is a
        // NON-modular mapping of the host's u32 90kHz RTP timestamp, so it
        // COLLAPSES from ~47.7e9µs toward 0 when the host clock crosses 2^32
        // (period ~13.26h, origin arbitrary - the wrap can land mid-session).
        // A wrapping `&-` delta here goes astronomically large at that collapse
        // and clears receivedOosData on a still-reordering link - failing OPEN,
        // so the next cross-frame reorder is declared an immediate unrecoverable
        // loss (spurious RFI + one dropped frame, the exact false-loss hitch the
        // hold exists to prevent). The plain `>` instead goes FALSE at the wrap:
        // we stay in OOS mode (fail CLOSED) and the next OOS observation
        // re-latches lastOosPresentationUs past the wrap, restoring the cooldown
        // clock. No overflow risk: lastOos tops out near 47.7e9 and the cooldown
        // is 3e8, both far under UInt64.max.
        if receivedOosData {
            let presentationUs = (UInt64(timestamp) * 1000) / 90
            if presentationUs > lastOosPresentationUs + Self.speculativeRfiCooldownUs {
                receivedOosData = false
            }
        }

        // NV header fields are LITTLE-endian, at dataOffset. We only read the
        // fields this stage needs: streamPacketIndex (nv+0) and flags/extraFlags
        // (nv+8/+9) are re-parsed in the emit path; multiFecFlags (nv+10) is
        // unused on this path (the block index/count come from multiFecBlocks).
        let nv = rtp.dataOffset
        let fecInfo = le32(bytes, nv + 12)
        // Legacy fixup for non-multi-FEC servers (we're multiFecCapable, so this
        // branch never runs for our host, but keep it faithful).
        let multiFecBlocks: UInt8 = multiFecCapable ? bytes[nv + 11] : 0x00
        let fields = NvFields(
            frameIndex: le32(bytes, nv + 4),
            fecIndex: (fecInfo & 0x3FF000) >> 12,
            fecCurrentBlockNumber: (multiFecBlocks >> 4) & 0x3,
            multiFecBlocks: multiFecBlocks,
            fecInfo: fecInfo)

        // Reject frames behind our current frame number.
        if Self.isBefore32(fields.frameIndex, currentFrameNumber) {
            return .rejected
        }

        // Issue 2b: a deferred next-frame packet is held ONLY to give the
        // CURRENT frame's late shards time to land. If the incoming datagram is
        // NOT for the current frame (it's another later frame, or even the
        // deferred frame's own next packet), the hold can no longer help - flush
        // the deferred packet first so frame N's loss is declared and N+1 opens
        // in order BEFORE we process this datagram. This is what keeps the
        // one-deep slot from ever stranding the deferred SOF. A packet that DOES
        // belong to the current frame (frameIndex == currentFrameNumber, the late
        // shard we're waiting for) is left to complete N, then the completion
        // path replays the deferred packet.
        if deferredDatagram != nil, fields.frameIndex != currentFrameNumber {
            replayDeferredDatagram()
        }

        if fields.frameIndex == currentFrameNumber
            && fields.fecCurrentBlockNumber < multiFecCurrentBlockNumber {
            return .rejected
        }

        // New frame / new FEC block?
        if pending.isEmpty || currentFrameNumber != fields.frameIndex
            || multiFecCurrentBlockNumber != fields.fecCurrentBlockNumber {
            switch handleFrameTransition(rtp, fields: fields, receiveTimeUs: receiveTimeUs,
                                         allowHold: allowHold) {
            case .proceed: break
            case .finished(let result): return result
            }
        }

        // Reject packets above the FEC window.
        if Self.isBefore16(bufferHighestSequenceNumber, seq) {
            return .rejected
        }

        let isParity = !Self.isBefore16(seq, bufferFirstParitySequenceNumber)
        let entry = Entry(bytes: bytes, length: rtp.length, seq: seq, ts: timestamp,
                          ssrc: rtp.ssrc, header: rtp.header, isParity: isParity)
        if !queuePacket(entry) {
            return .rejected
        }

        updateReceiveCounts(seq: seq)

        // Try to reconstruct + submit the frame.
        if reconstructFrame() == 0 {
            completeFecBlockOrFrame()
        }

        return .queued
    }

    /// Handle the new-frame / new-FEC-block transition (RtpVideoQueue.c:583-744):
    /// the bounded cross-frame reorder hold, the unrecoverable-frame reporting +
    /// drop paths, and - when we genuinely advance - the per-frame buffer-window
    /// reset. Returns `.proceed` to continue the add with the freshly opened
    /// window, or `.finished` with the terminal result (a reorder hold `.queued`
    /// or a dropped frame `.rejected`).
    private func handleFrameTransition(_ rtp: ParsedRtp, fields: NvFields,
                                       receiveTimeUs: UInt64, allowHold: Bool) -> TransitionOutcome {
        let frameIndex = fields.frameIndex

        // Issue 2b - BOUNDED CROSS-FRAME REORDER HOLD. The next frame's first
        // packet has arrived while the current frame is still incomplete. On
        // a link we've SEEN reorder (receivedOosData), the current frame's
        // late tail/EOF shards are probably microseconds away and FEC can
        // still complete it - so defer this next-frame packet for a bounded
        // window instead of immediately declaring loss. Strictly gated:
        //   * receivedOosData          - only on a proven-reordering link
        //   * currentFrameNumber != frameIndex && !pending.isEmpty
        //                              - genuinely "next frame started, this
        //                                frame incomplete" (not a new FEC
        //                                block of the same frame)
        //   * isFecRecoveryStillPossible - FEC can still recover with the
        //                                parity we expect (never hold a frame
        //                                that's already unrecoverable)
        //   * deferredDatagram == nil  - one-deep: a SECOND new frame forces
        //                                immediate loss (no unbounded stall)
        //   * within reorderWindowUs   - time bound from the frame's first
        //                                receive
        // A held packet returns .queued WITHOUT advancing currentFrameNumber;
        // it's replayed once the late shard lands (the next datagram re-drives
        // addPacket) or the window elapses (flushDeferredIfWindowElapsed).
        if allowHold,
           receivedOosData,
           !pending.isEmpty,
           currentFrameNumber != frameIndex,
           deferredDatagram == nil,
           isFecRecoveryStillPossible(),
           receiveTimeUs &- bufferFirstRecvTimeUs < reorderWindowUs {
            deferredDatagram = (rtp.bytes, receiveTimeUs)
            return .finished(.queued)
        }

        if !pending.isEmpty {
            // Report the final status of the FEC queue before dropping this
            // frame (RtpVideoQueue.c:596-597) - the per-frame reception
            // feedback Sunshine's QoS eval needs.
            reportFinalFrameFecStatus()

            // Handle multi-FEC mid-frame block loss.
            if multiFecLastBlockNumber != 0 {
                Diag.warn("NativeVideo unrecoverable frame \(currentFrameNumber) "
                    + "(block \(multiFecCurrentBlockNumber + 1)/\(multiFecLastBlockNumber + 1)): "
                    + "\(receivedDataPackets)+\(receivedParityPackets) < \(bufferDataPackets) needed", Self.cat)
                if currentFrameNumber == frameIndex {
                    TelemetryCounters.shared.unrecoverableFrameTotal.increment()
                    purgeAll()
                    if !reportedLostFrame {
                        depacketizer.queueLostFrame(Int(currentFrameNumber))
                        reportedLostFrame = true
                    }
                    currentFrameNumber &+= 1
                    multiFecCurrentBlockNumber = 0
                    return .finished(.rejected)
                }
            } else {
                Diag.warn("NativeVideo unrecoverable frame \(currentFrameNumber): "
                    + "\(receivedDataPackets)+\(receivedParityPackets)=\(pending.count) < \(bufferDataPackets) needed", Self.cat)
                TelemetryCounters.shared.unrecoverableFrameTotal.increment()
            }
        }

        let expectedFecBlock: UInt8 = (currentFrameNumber == frameIndex) ? multiFecCurrentBlockNumber : 0
        if fields.fecCurrentBlockNumber != expectedFecBlock {
            // Report the final status of the FEC queue before dropping this
            // frame (RtpVideoQueue.c:640-641).
            reportFinalFrameFecStatus()
            Diag.warn("NativeVideo unrecoverable frame \(frameIndex): lost FEC blocks "
                + "\(expectedFecBlock + 1)..\(fields.fecCurrentBlockNumber)", Self.cat)
            TelemetryCounters.shared.unrecoverableFrameTotal.increment()
            purgeAll()
            if !reportedLostFrame {
                depacketizer.queueLostFrame(Int(currentFrameNumber))
                reportedLostFrame = true
            }
            currentFrameNumber = frameIndex &+ 1
            multiFecCurrentBlockNumber = 0
            return .finished(.rejected)
        }

        // Discard pending from previous FEC block.
        pending.removeAll(keepingCapacity: true)
        // Discard completed from a previous frame.
        if currentFrameNumber != frameIndex {
            completed.removeAll(keepingCapacity: true)
            // Advancing to a NEW frame: reset the per-frame FEC-recovery latch
            // (a recovery in a previous frame's earlier block must not leak into
            // this frame's metric if that frame was dropped before submitting).
            currentFrameNeededFec = false

            // Whole-frame loss detection (non-contiguous frameIndex).
            if currentFrameNumber &+ 1 != frameIndex || !reportedLostFrame {
                depacketizer.queueLostFrame(Int(frameIndex) - 1)
            }
        }

        openFrameWindow(rtp, fields: fields, receiveTimeUs: receiveTimeUs)
        return .proceed
    }

    /// Reset the per-frame buffer-window state for the frame/FEC block we're now
    /// accumulating (RtpVideoQueue.c:746-767): sequence-number bounds derived from
    /// the fecInfo data/parity split, the per-frame received-packet counters, and
    /// the multi-FEC block bookkeeping.
    private func openFrameWindow(_ rtp: ParsedRtp, fields: NvFields, receiveTimeUs: UInt64) {
        let fecInfo = fields.fecInfo
        currentFrameNumber = fields.frameIndex

        bufferFirstRecvTimeUs = receiveTimeUs
        bufferLowestSequenceNumber = Self.u16(Int(rtp.seq) - Int(fields.fecIndex))
        nextContiguousSequenceNumber = bufferLowestSequenceNumber
        receivedDataPackets = 0
        receivedParityPackets = 0
        receivedHighestSequenceNumber = 0
        missingPackets = 0
        useFastQueuePath = true
        reportedLostFrame = false
        bufferDataPackets = Int((fecInfo & 0xFFC00000) >> 22)
        fecPercentage = Int((fecInfo & 0xFF0) >> 4)
        bufferParityPackets = (bufferDataPackets * fecPercentage + 99) / 100
        bufferFirstParitySequenceNumber = Self.u16(Int(bufferLowestSequenceNumber) + bufferDataPackets)
        bufferHighestSequenceNumber = Self.u16(Int(bufferFirstParitySequenceNumber) + bufferParityPackets - 1)
        multiFecCurrentBlockNumber = fields.fecCurrentBlockNumber
        multiFecLastBlockNumber = (fields.multiFecBlocks >> 6) & 0x3
    }

    /// Fold one freshly queued packet into the missing/received counters
    /// (RtpVideoQueue.c:771-792). `seq` is the packet's host-order sequence number.
    private func updateReceiveCounts(seq: UInt16) {
        if pending.count == 1 {
            missingPackets += Int(Self.u16(Int(seq) - Int(bufferLowestSequenceNumber)))
            receivedHighestSequenceNumber = seq
        } else if Self.isBefore16(receivedHighestSequenceNumber, seq) {
            missingPackets += Int(Self.u16(Int(seq) - Int(receivedHighestSequenceNumber) - 1))
            receivedHighestSequenceNumber = seq
        } else if missingPackets > 0 {
            missingPackets -= 1
        }

        if Self.isBefore16(seq, bufferFirstParitySequenceNumber) {
            receivedDataPackets += 1
        } else {
            receivedParityPackets += 1
        }
    }

    /// A reconstruct succeeded: stage the complete FEC block, then either advance
    /// to the next multi-FEC block or submit the now-complete frame and open the
    /// next one (RtpVideoQueue.c:795-803, plus the Issue 2b deferred replay).
    private func completeFecBlockOrFrame() {
        stageCompleteFecBlock()

        if multiFecCurrentBlockNumber < multiFecLastBlockNumber {
            multiFecCurrentBlockNumber += 1
        } else {
            submitCompletedFrame()
            currentFrameNumber &+= 1
            multiFecCurrentBlockNumber = 0
            // Issue 2b: the held current frame just completed via its late
            // shard. Replay the deferred next-frame packet now so the next
            // frame opens normally - strict in-order submit is preserved (we
            // never reorder frames into the depacketizer; we only delayed the
            // loss DECISION). Replay drives addPacket re-entrantly, but the
            // one-deep slot is cleared first so depth is bounded to 1.
            replayDeferredDatagram()
        }
    }

    // MARK: - Reorder-hold helpers (Issue 2b)

    /// FEC could still recover the current frame: the data deficit is within the
    /// parity we expect to receive for this block. Never hold a frame that's
    /// already mathematically unrecoverable - that's genuine loss, declare it.
    private func isFecRecoveryStillPossible() -> Bool {
        // Need fecPercentage > 0 (otherwise no parity can ever fill the gap) and
        // the count of still-missing DATA packets must not exceed the parity we
        // expect for the block.
        guard bufferParityPackets > 0 else { return false }
        let dataDeficit = bufferDataPackets - receivedDataPackets
        return dataDeficit <= bufferParityPackets
    }

    /// Replay a deferred next-frame datagram (the held cross-frame-reorder
    /// packet). Clears the slot BEFORE re-driving addPacket so the re-entrant
    /// call can't re-defer the same bytes (depth bounded to 1).
    func replayDeferredDatagram() {
        guard let held = deferredDatagram else { return }
        deferredDatagram = nil
        dispatchDatagram(held.bytes, receiveTimeUs: held.receiveTimeUs, isReplay: true)
    }

    /// If a deferred next-frame packet is outstanding and the current frame's
    /// reorder window has elapsed, replay it now. Called at the top of
    /// addRawDatagram so the late tail shard gets at most `reorderWindowUs` of
    /// grace; once the window is up the deferred packet re-drives addPacket and
    /// the unmodified loss path declares the (genuinely lost) current frame.
    func flushDeferredIfWindowElapsed(nowUs: UInt64) {
        guard deferredDatagram != nil else { return }
        if nowUs &- bufferFirstRecvTimeUs >= reorderWindowUs {
            replayDeferredDatagram()
        }
    }

    // MARK: - queuePacket (c:111-182)

    func queuePacket(_ newEntry: Entry) -> Bool {
        if useFastQueuePath && newEntry.sequenceNumber == nextContiguousSequenceNumber {
            nextContiguousSequenceNumber = Self.u16(Int(newEntry.sequenceNumber) + 1)
        } else {
            // Check for duplicates / out-of-sequence. While we walk pending,
            // detect genuine REORDER: any already-queued entry whose seq comes
            // AFTER the new entry's seq means this packet arrived late/out of
            // order. Latch receivedOosData so the cross-frame reorder hold turns
            // on for this (reordering) link (RtpVideoQueue.c:139-141,162-170).
            for entry in pending {
                if entry.sequenceNumber == newEntry.sequenceNumber {
                    return false
                }
                if Self.isBefore16(newEntry.sequenceNumber, entry.sequenceNumber) {
                    receivedOosData = true
                    lastOosPresentationUs = newEntry.presentationTimeUs
                }
            }
            useFastQueuePath = false
        }
        pending.append(newEntry)
        return true
    }

    private func purgeAll() {
        pending.removeAll(keepingCapacity: true)
        completed.removeAll(keepingCapacity: true)
    }
}
