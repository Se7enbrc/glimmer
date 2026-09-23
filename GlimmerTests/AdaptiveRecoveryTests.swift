//
//  AdaptiveRecoveryTests.swift
//
//  Video decode recovery and the adaptive controllers: the env-signal classifier and its decision,
//  the RTP queue's fixed reorder hold and datagram clock, and the decoder's resync latch, stall
//  escalation and reconnect-while-hidden gate.
//

import Foundation
import QuartzCore
import Testing
@testable import Glimmer

// MARK: - Env-signal window classifier

struct EnvSignalEvidenceTests {

    private func window(video: Bool = true, retransmit: UInt64 = 0,
                        jitterMs: Double = 0) -> EnvSignalController.WindowEvidence {
        var evidence = EnvSignalController.WindowEvidence()
        evidence.videoArrived = video
        evidence.retransmit = retransmit
        evidence.maxJitterMs = jitterMs
        return evidence
    }

    private func close(_ evidence: EnvSignalController.WindowEvidence,
                       on controller: EnvSignalController) {
        controller.window = evidence
        controller.evaluateWindow(link: .wifi)
    }

    /// A dead stream (asleep, undocked) piles up ENet retransmits with no video.
    /// Those windows carry no link evidence and must neither escalate nor reset.
    @Test func windowsWithoutVideoLeaveTheRunsAlone() {
        let controller = EnvSignalController()
        close(window(retransmit: 10), on: controller)
        close(window(retransmit: 10), on: controller)
        #expect(controller.degradedRun == 2)
        for _ in 0..<10 { close(window(video: false, retransmit: 700), on: controller) }
        #expect(controller.degradedRun == 2)
        #expect(controller.state == .clear)
    }

    /// The same retransmit storm with video flowing is real evidence and still
    /// escalates after the sustained (non-co-gap) run.
    @Test func liveRetransmitStormStillEscalates() {
        let controller = EnvSignalController()
        for _ in 0..<EnvSignalController.radioOnlyEscalateWindows {
            close(window(retransmit: 10), on: controller)
        }
        #expect(controller.state == .caution)
    }

    /// CAUTION is labelled with the evidence the run actually held.
    @Test func cautionReasonNamesTheEvidence() {
        #expect(EnvSignalController.cautionReason(coGap: false, radioSag: false)
            == "sustained_jitter_retransmit")
        #expect(EnvSignalController.cautionReason(coGap: false, radioSag: true) == "sustained_radio_sag")
        #expect(EnvSignalController.cautionReason(coGap: true, radioSag: true) == "sustained_co_gaps")
    }

    /// Ending the session withdraws an escalated decision: generation 0 is what
    /// sends every pacer back to deciding from its own jitter reading.
    @Test func endSessionWithdrawsThePublishedDecision() {
        let controller = EnvSignalController()
        for _ in 0..<EnvSignalController.radioOnlyEscalateWindows + 1 {
            close(window(jitterMs: 30), on: controller)
        }
        #expect(controller.decision.headroomLevel > 0)
        #expect(controller.decision.generation > 0)
        controller.endSession()
        let decision = controller.decision
        #expect(decision.headroomLevel == 0)
        #expect(decision.smoothedJitterMs == 0)
        #expect(decision.generation == 0)
    }
}

// MARK: - RTP queue: reorder hold, FEC rebuild and datagram clock

/// Serialized: the hold counters and the datagram clock are process-global.
@Suite(.serialized)
struct RtpVideoQueueRecoveryTests {

    private final class NoopDelegate: VideoDepacketizerDelegate {
        func depacketizerDidAssembleFrame(_ unit: DecodeUnit) {}
        func depacketizerDetectedFrameLoss(from: Int, to: Int) {}
        func depacketizerNeedsIdr() {}
        func depacketizerReceivedKeyFrame(frameNumber: Int) {}
    }

    private let delegate = NoopDelegate()

    private func makeQueue() -> RtpVideoQueue {
        let depacketizer = VideoDepacketizer(delegate: delegate,
                                             negotiatedVideoFormat: StreamProtocol.VIDEO_FORMAT_H265,
                                             colorSpace: 0)
        return RtpVideoQueue(depacketizer: depacketizer, packetSize: 64)
    }

    /// One data shard of a two-data, one-parity frame (fecPercentage 50).
    private func datagram(seq: UInt16, frame: UInt32, fecIndex: UInt32, flags: UInt8) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 16 + 16 + 8)
        bytes[0] = RtpVideoQueue.FLAG_EXTENSION
        bytes[2] = UInt8(seq >> 8)
        bytes[3] = UInt8(seq & 0xFF)
        let fecInfo: UInt32 = (2 << 22) | (fecIndex << 12) | (50 << 4)
        for byte in 0..<4 {
            bytes[16 + 4 + byte] = UInt8((frame >> (8 * UInt32(byte))) & 0xFF)
            bytes[16 + 12 + byte] = UInt8((fecInfo >> (8 * UInt32(byte))) & 0xFF)
        }
        bytes[16 + 8] = flags | RtpVideoQueue.FLAG_CONTAINS_PIC_DATA
        return bytes
    }

    /// On a reordering link, the next frame's first packet is held while the
    /// current frame's late shard lands; the frame completes and counts as rescued.
    @Test func reorderHoldIsTakenAndRescued() {
        let counters = TelemetryCounters.shared
        let taken = counters.reorderHoldTakenTotal.value, rescued = counters.reorderHoldRescuedTotal.value
        let queue = makeQueue()
        queue.receivedOosData = true
        queue.addRawDatagram(datagram(seq: 0, frame: 1, fecIndex: 0, flags: RtpVideoQueue.FLAG_SOF),
                             receiveTimeUs: 1_000)
        queue.addRawDatagram(datagram(seq: 3, frame: 2, fecIndex: 0, flags: RtpVideoQueue.FLAG_SOF),
                             receiveTimeUs: 2_000)
        #expect(counters.reorderHoldTakenTotal.value == taken + 1)
        #expect(counters.reorderHoldRescuedTotal.value == rescued)
        queue.addRawDatagram(datagram(seq: 1, frame: 1, fecIndex: 1, flags: RtpVideoQueue.FLAG_EOF),
                             receiveTimeUs: 3_000)
        #expect(counters.reorderHoldRescuedTotal.value == rescued + 1)
        #expect(queue.currentFrameNumber == 2)
    }

    /// A shard FEC rebuilt lands behind its parity by construction: it must not
    /// mark the link as reordering. A late packet off the wire must.
    @Test func onlyWireReordersLatchOutOfOrder() {
        let queue = makeQueue()
        func entry(_ seq: UInt16) -> RtpVideoQueue.Entry {
            RtpVideoQueue.Entry(bytes: [], length: 0, seq: seq, ts: 0, ssrc: 0, header: 0, isParity: false)
        }
        queue.useFastQueuePath = false
        #expect(queue.queuePacket(entry(5), isFecRecovery: false))
        #expect(queue.queuePacket(entry(4), isFecRecovery: true))
        #expect(!queue.receivedOosData)
        #expect(queue.queuePacket(entry(3), isFecRecovery: false))
        #expect(queue.receivedOosData)
    }

    /// Writes the RTP and NV fields Sunshine stamps on every shard after encoding:
    /// shard `index` of block 0 of 2 in frame 1, three data shards at 50% FEC.
    private func stampShard(_ shard: inout [UInt8], index: Int) {
        shard[0] = RtpVideoQueue.FLAG_EXTENSION
        shard[2] = 0
        shard[3] = UInt8(index)
        let fecInfo = UInt32(index << 12 | 3 << 22 | 50 << 4)
        for byte in 0..<4 {
            shard[16 + 4 + byte] = byte == 0 ? 1 : 0
            shard[16 + 12 + byte] = UInt8(truncatingIfNeeded: fecInfo >> (8 * byte))
        }
        shard[16 + 11] = 1 << 6
    }

    /// A PC that caps the packet size sends shards shorter than the 80 bytes asked for.
    /// A rebuilt middle shard keeps the real length, since padding would put zeros
    /// inside the frame. At the requested size the rebuild is unchanged.
    @Test(arguments: [80, 64])
    func lostShardIsRebuiltAtTheRealShardLength(shardSize: Int) throws {
        let queue = makeQueue()
        var data = (0..<3).map { i in (0..<shardSize).map { UInt8(truncatingIfNeeded: 5 + i * 31 + $0 * 7) } }
        let flags = [RtpVideoQueue.FLAG_SOF, 0, RtpVideoQueue.FLAG_EOF]
        for index in 0..<3 {
            stampShard(&data[index], index: index)
            data[index][16 + 8] = flags[index] | RtpVideoQueue.FLAG_CONTAINS_PIC_DATA
        }
        var parity = ReedSolomonTests.cauchyParity(data: data, ds: 3, ps: 2, bs: shardSize)
        stampShard(&parity[0], index: 3)

        for shard in [data[0], data[2], parity[0]] {
            queue.addRawDatagram(shard, receiveTimeUs: DispatchTime.now().uptimeNanoseconds / 1000)
        }
        let rebuilt = try #require(queue.completed.first { $0.sequenceNumber == 1 })
        #expect(queue.completed.count == 3)
        #expect(rebuilt.length == shardSize)
        #expect(rebuilt.bytes[16 + 8] == data[1][16 + 8])
        #expect(rebuilt.bytes[32..<rebuilt.length] == data[1][32...])
    }

    /// Reception is alive while datagrams arrive, even when no frame survives
    /// to the decoder (the downshift's whole premise).
    @Test @MainActor func datagramsKeepReceptionAliveWithoutFrames() {
        _ = makeQueue()
        let decoder = VideoDecoder()
        #expect(decoder.secondsSinceLastReceivedFrame() == .infinity)
        makeQueue().addRawDatagram([0, 0, 0], receiveTimeUs: DispatchTime.now().uptimeNanoseconds / 1000)
        #expect(decoder.secondsSinceLastReceivedFrame() < 1)
    }

    /// The env-signal fold credits a window with video only when the datagram
    /// clock moved between ticks.
    @Test func envWindowSeesVideoOnlyWhenDatagramsArrive() {
        let queue = makeQueue()
        let controller = EnvSignalController()
        controller.degradedRun = 1
        controller.observeCaptureTick(route: nil, wifi: nil)
        controller.observeCaptureTick(route: nil, wifi: nil)
        #expect(controller.degradedRun == 1)
        controller.observeCaptureTick(route: nil, wifi: nil)
        queue.addRawDatagram([0, 0, 0], receiveTimeUs: DispatchTime.now().uptimeNanoseconds / 1000)
        controller.observeCaptureTick(route: nil, wifi: nil)
        #expect(controller.degradedRun != 1)
    }
}

// MARK: - Decoder resync and stall escalation

@MainActor
struct VideoDecoderRecoveryTests {

    /// A decoder mid-stream (no VT session: fed frames fail setup quietly).
    private func streamingDecoder() -> VideoDecoder {
        let decoder = VideoDecoder()
        decoder.isStreaming = true
        return decoder
    }

    private func submit(_ decoder: VideoDecoder, idr: Bool) -> Int32 {
        decoder.decodeAssembledFrame(pictureData: Data([0]), newSps: nil, newPps: nil, newVps: nil,
                                     isIDR: idr, rtpTimestamp: 0, totalLength: 1)
    }

    /// A VT failure makes the next P-frame flush to IDR, once. A failure from a
    /// frame an IDR has since superseded is stale and changes nothing.
    @Test func decodeFailureResyncsOnceAndIgnoresStaleEpochs() {
        let decoder = streamingDecoder()
        #expect(submit(decoder, idr: false) == StreamProtocol.DR_OK)
        #expect(submit(decoder, idr: true) == StreamProtocol.DR_OK)
        decoder.noteVtDecodeFailure(epoch: 0, status: -12909)
        #expect(submit(decoder, idr: false) == StreamProtocol.DR_OK)
        decoder.noteVtDecodeFailure(epoch: 1, status: -12909)
        #expect(submit(decoder, idr: false) == StreamProtocol.DR_NEED_IDR)
        #expect(submit(decoder, idr: false) == StreamProtocol.DR_OK)
    }

    /// An IDR arriving after a failure feeds straight through and clears it.
    @Test func idrAfterFailureFeeds() {
        let decoder = streamingDecoder()
        decoder.noteVtDecodeFailure(epoch: 0, status: -12911)
        #expect(submit(decoder, idr: true) == StreamProtocol.DR_OK)
        #expect(submit(decoder, idr: false) == StreamProtocol.DR_OK)
    }

    /// After stop, a failure (VT flushing on teardown) arms nothing.
    @Test func failureAfterStopIsIgnored() {
        let decoder = VideoDecoder()
        decoder.noteVtDecodeFailure(epoch: 0, status: -12903)
        decoder.isStreaming = true
        #expect(submit(decoder, idr: false) == StreamProtocol.DR_OK)
    }

    /// A dead session frees every slot, so the backlog never fills: VT's own
    /// failure verdict lets a late IDR rebuild it. A healthy pause does not.
    @Test func deadSessionRecreatesAtAnyBacklog() {
        let decoder = VideoDecoder()
        decoder.statsCollector.lastDecodedFrameTime = CACurrentMediaTime() - 5
        #expect(decoder.reserveDecodeSlot(isIDR: true) == .reserved)
        decoder.releaseInFlightDecode(vtFailed: true)
        #expect(decoder.reserveDecodeSlot(isIDR: false) == .reserved)
        #expect(decoder.reserveDecodeSlot(isIDR: true) == .reservedForStallRecreate)
        #expect(decoder.inFlightDecodeBacklog() == 1)
    }

    /// Right after the hidden-window gate lifts, VT's dark span is the gate's,
    /// not a wedge: no recreate even with a failure on record.
    @Test func gateLiftFloorsTheDarkClock() {
        let decoder = VideoDecoder()
        decoder.statsCollector.lastDecodedFrameTime = CACurrentMediaTime() - 60
        decoder.releaseInFlightDecode(vtFailed: true)
        decoder.presentSuppressedLock.lock()
        decoder._decodeGateLiftedAtNanos = DispatchTime.now().uptimeNanoseconds
        decoder.presentSuppressedLock.unlock()
        #expect(decoder.reserveDecodeSlot(isIDR: true) == .reserved)
    }

    /// Sleep/wake with the window hidden: the reconnect's stop clears an engaged
    /// gate, so the connect edge must re-arm it or every frame decodes unseen.
    @Test func reconnectWhileHiddenGatesDecodeAgain() async throws {
        let decoder = VideoDecoder()
        decoder.handleStart()
        decoder.setPresentSuppressed(true)
        decoder.cancelDecodeGateTimer()
        decoder.handleStop()
        decoder.handleStart()
        for _ in 0..<50 where !decoder.decodeGated {
            try await Task.sleep(for: .milliseconds(100))
        }
        #expect(decoder.decodeGated)
        decoder.teardown()
    }

    /// A reconnect that renegotiates the bitrate updates what telemetry reports.
    @Test func negotiatedBitrateFollowsTheReconnect() async {
        let decoder = VideoDecoder()
        decoder.setNegotiatedBitrateKbps(361_600)
        await Task.detached { decoder.setNegotiatedBitrateKbps(180_000) }.value
        #expect(decoder.telemetryStatsSnapshot().negotiatedBitrateMbps == 180)
    }
}
