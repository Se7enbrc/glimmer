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

    private let delegate = RecordingDepacketizerDelegate()

    private func makeQueue(av1: Bool = false) -> RtpVideoQueue {
        let depacketizer = VideoDepacketizer(delegate: delegate,
                                             negotiatedVideoFormat: av1
                                                ? StreamProtocol.VIDEO_FORMAT_AV1_MAIN8
                                                : StreamProtocol.VIDEO_FORMAT_H265,
                                             colorSpace: 0)
        return RtpVideoQueue(depacketizer: depacketizer, packetSize: 64)
    }

    /// One data shard of a two-data, one-parity frame (fecPercentage 50).
    private func datagram(seq: UInt16, frame: UInt32, fecIndex: UInt32, flags: UInt8,
                          dataCount: UInt32 = 2, fecPercent: UInt32 = 50,
                          timestamp: UInt32 = 0) -> [UInt8] {
        var bytes = [UInt8](repeating: 0, count: 16 + 16 + 8)
        bytes[0] = RtpVideoQueue.FLAG_EXTENSION
        bytes[2] = UInt8(seq >> 8)
        bytes[3] = UInt8(seq & 0xFF)
        for byte in 0..<4 { bytes[4 + byte] = UInt8(truncatingIfNeeded: timestamp >> (24 - byte * 8)) }
        let fecInfo: UInt32 = (dataCount << 22) | (fecIndex << 12) | (fecPercent << 4)
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

    /// Stamp each shard after parity encoding, as Sunshine does on the wire.
    private func stampShard(_ shard: inout [UInt8], index: Int, block: UInt8 = 0,
                            lastBlock: UInt8 = 1, seq: UInt16? = nil,
                            dataCount: Int = 3, fecPercent: Int = 50, spi: Int? = nil) {
        shard[0] = RtpVideoQueue.FLAG_EXTENSION
        let sequence = seq ?? UInt16(index)
        shard[2] = UInt8(sequence >> 8)
        shard[3] = UInt8(truncatingIfNeeded: sequence)
        if let spi { shard[16 + 1] = UInt8(truncatingIfNeeded: spi) }
        let fecInfo = UInt32(index << 12 | dataCount << 22 | fecPercent << 4)
        for byte in 0..<4 {
            shard[16 + 4 + byte] = byte == 0 ? 1 : 0
            shard[16 + 12 + byte] = UInt8(truncatingIfNeeded: fecInfo >> (8 * byte))
        }
        shard[16 + 11] = ((lastBlock << 2) | block) << 4
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

    private func twoBlockShards(firstSeq: UInt16 = 0, frame: UInt32 = 1) -> [[UInt8]] {
        var shards: [[UInt8]] = []
        for block in 0..<2 {
            var data = [[UInt8]](repeating: [UInt8](repeating: 0, count: 40), count: 2)
            for index in 0..<2 {
                let ordinal = block * 2 + index
                stampShard(&data[index], index: index, block: UInt8(block),
                           seq: firstSeq &+ UInt16(block * 3 + index), dataCount: 2, spi: ordinal)
                data[index][16 + 4] = UInt8(truncatingIfNeeded: frame)
                data[index][16 + 8] = (ordinal == 0 ? RtpVideoQueue.FLAG_SOF : 0)
                    | (index == 1 ? RtpVideoQueue.FLAG_EOF : 0)
                    | RtpVideoQueue.FLAG_CONTAINS_PIC_DATA
                data[index][32] = UInt8(0x40 + ordinal)
            }
            if block == 0 {
                data[0][32...39] = [1, 0, 0, 2, 1, 0, 0, 0]
            }
            var parity = ReedSolomonTests.cauchyParity(data: data, ds: 2, ps: 1, bs: 40)[0]
            stampShard(&parity, index: 2, block: UInt8(block),
                       seq: firstSeq &+ UInt16(block * 3 + 2), dataCount: 2)
            shards.append(contentsOf: data + [parity])
        }
        return shards
    }

    @Test func completeTwoBlockFrameEmitsInOrder() throws {
        let queue = makeQueue(av1: true)
        let shards = twoBlockShards()
        for index in [0, 1, 3, 4] { queue.addRawDatagram(shards[index], receiveTimeUs: 1_000) }
        let unit = try #require(delegate.units.first)
        #expect(delegate.units.count == 1)
        #expect(unit.buffers.first?.data == Data(shards[1][32...] + shards[3][32...] + [0x43]))
        #expect(queue.currentFrameNumber == 2)
    }

    @Test func recoveredShardInSecondBlockCompletesFrame() throws {
        let shards = twoBlockShards()
        let probe = makeQueue(av1: true)
        for index in [0, 1, 3] { probe.addRawDatagram(shards[index], receiveTimeUs: 1_000) }
        let parity = RtpVideoQueue.Entry(bytes: shards[5], length: shards[5].count,
                                         seq: 5, ts: 0, ssrc: 0,
                                         header: shards[5][0], isParity: true)
        probe.pending.append(parity)
        #expect(probe.reconstructFrame() == 0)
        let rebuilt = try #require(probe.pending.first { $0.sequenceNumber == 4 })
        #expect(rebuilt.bytes[16 + 11] == 0x50)

        let queue = makeQueue(av1: true)
        for index in [0, 1, 3, 5] { queue.addRawDatagram(shards[index], receiveTimeUs: 1_000) }
        let unit = try #require(delegate.units.first)
        #expect(delegate.units.count == 1)
        #expect(unit.buffers.first?.data == Data(shards[1][32...] + shards[3][32...] + [0x43]))
        #expect(queue.currentFrameNumber == 2)
    }

    @Test func shortFirstBlockDropsFrameOnSecondBlock() {
        let queue = makeQueue(av1: true)
        queue.depacketizer.process(VideoDepacketizer.CompletedPacket(
            frameIndex: 1, flags: 0x07, extraFlags: 0, fecCurrentBlock: 0, fecLastBlock: 0,
            streamPacketIndex: 0, rtpTimestamp: 0, presentationTimeUs: 1_000,
            receiveTimeUs: 1_000, payload: [1, 0, 0, 2, 9, 0, 0, 0, 0x31]))
        queue.currentFrameNumber = 2
        let shards = twoBlockShards(frame: 2)
        queue.addRawDatagram(shards[0], receiveTimeUs: 1_000)
        queue.addRawDatagram(shards[3], receiveTimeUs: 2_000)
        #expect(delegate.losses.map(\.to) == [2])
        #expect(queue.currentFrameNumber == 3)
        #expect(queue.completed.isEmpty)
    }

    @Test func holdIsRefusedWhenDeficitExceedsParity() {
        let queue = makeQueue()
        queue.receivedOosData = true
        queue.addRawDatagram(datagram(seq: 0, frame: 1, fecIndex: 0,
                                      flags: RtpVideoQueue.FLAG_SOF, dataCount: 4, fecPercent: 25),
                             receiveTimeUs: 1_000)
        queue.addRawDatagram(datagram(seq: 5, frame: 2, fecIndex: 0,
                                      flags: RtpVideoQueue.FLAG_SOF, dataCount: 4, fecPercent: 25),
                             receiveTimeUs: 2_000)
        #expect(queue.deferredDatagram == nil)
        #expect(queue.currentFrameNumber == 2)
    }

    @Test func holdIsRefusedWithoutParity() {
        let queue = makeQueue()
        queue.receivedOosData = true
        queue.addRawDatagram(datagram(seq: 0, frame: 1, fecIndex: 0,
                                      flags: RtpVideoQueue.FLAG_SOF, fecPercent: 0), receiveTimeUs: 1_000)
        queue.addRawDatagram(datagram(seq: 2, frame: 2, fecIndex: 0,
                                      flags: RtpVideoQueue.FLAG_SOF, fecPercent: 0), receiveTimeUs: 2_000)
        #expect(queue.deferredDatagram == nil)
        #expect(queue.currentFrameNumber == 2)
    }

    @Test func oosCooldownStaysLatchedAcrossTimestampWrap() {
        let queue = makeQueue()
        queue.receivedOosData = true
        queue.lastOosPresentationUs = (UInt64(UInt32.max - 100) * 1000) / 90
        queue.addRawDatagram(datagram(seq: 0, frame: 1, fecIndex: 0,
                                      flags: RtpVideoQueue.FLAG_SOF, timestamp: UInt32.max - 10),
                             receiveTimeUs: 1_000)
        queue.addRawDatagram(datagram(seq: 1, frame: 1, fecIndex: 1,
                                      flags: RtpVideoQueue.FLAG_EOF, timestamp: 5),
                             receiveTimeUs: 2_000)
        #expect(queue.receivedOosData)
    }

    @Test func fecRebuildCrossesSequenceWrapInOrder() throws {
        let queue = makeQueue(av1: true)
        queue.nextContiguousSequenceNumber = 0xFFFE
        var data = [[UInt8]](repeating: [UInt8](repeating: 0, count: 40), count: 3)
        for index in 0..<3 {
            stampShard(&data[index], index: index, lastBlock: 0,
                       seq: 0xFFFE &+ UInt16(index), spi: index)
            data[index][16 + 8] = (index == 0 ? RtpVideoQueue.FLAG_SOF : 0)
                | (index == 2 ? RtpVideoQueue.FLAG_EOF : 0)
                | RtpVideoQueue.FLAG_CONTAINS_PIC_DATA
            data[index][32] = UInt8(0x51 + index)
        }
        data[0][32...39] = [1, 0, 0, 2, 8, 0, 0, 0]
        var parity = ReedSolomonTests.cauchyParity(data: data, ds: 3, ps: 2, bs: 40)[0]
        stampShard(&parity, index: 3, lastBlock: 0, seq: 1)
        for shard in [data[0], data[2], parity] { queue.addRawDatagram(shard, receiveTimeUs: 1_000) }
        let unit = try #require(delegate.units.first)
        #expect(unit.buffers.first?.data == Data(data[1][32...] + data[2][32...]))
        #expect(queue.currentFrameNumber == 2)
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

    /// A decoder mid-stream with no VT session and format 0: any fed frame fails setup and arms the resync.
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
        #expect(decoder.decodeGateDisposition(isIDR: false) == .feed(epoch: 0))
        #expect(decoder.decodeGateDisposition(isIDR: true) == .feed(epoch: 1))
        decoder.noteVtDecodeFailure(epoch: 0, status: -12909)
        #expect(decoder.decodeGateDisposition(isIDR: false) == .feed(epoch: 1))
        decoder.noteVtDecodeFailure(epoch: 1, status: -12909)
        #expect(decoder.decodeGateDisposition(isIDR: false) == .resyncToIdr)
        #expect(decoder.decodeGateDisposition(isIDR: false) == .feed(epoch: 1))
    }

    /// An IDR arriving after a failure feeds straight through and clears it.
    @Test func idrAfterFailureFeeds() {
        let decoder = streamingDecoder()
        decoder.noteVtDecodeFailure(epoch: 0, status: -12911)
        #expect(decoder.decodeGateDisposition(isIDR: true) == .feed(epoch: 1))
        #expect(decoder.decodeGateDisposition(isIDR: false) == .feed(epoch: 1))
    }

    /// After stop, a failure (VT flushing on teardown) arms nothing.
    @Test func failureAfterStopIsIgnored() {
        let decoder = VideoDecoder()
        decoder.noteVtDecodeFailure(epoch: 0, status: -12903)
        decoder.isStreaming = true
        #expect(decoder.decodeGateDisposition(isIDR: false) == .feed(epoch: 0))
    }

    /// A decode session that can't be built resyncs through one DR_NEED_IDR on the next P-frame,
    /// not a bare keyframe request for every frame.
    @Test func sessionSetupFailureResyncsOnce() async {
        let decoder = streamingDecoder()
        #expect(submit(decoder, idr: true) == StreamProtocol.DR_OK)
        await decoder.decodeQueue.drainForTest()
        #expect(submit(decoder, idr: false) == StreamProtocol.DR_NEED_IDR)
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

    @Test func drainingDecoderAbsorbsBurstPastNominalBound() {
        let decoder = VideoDecoder()
        decoder.inFlightDecodes = decoder.maxInFlightDecodes
        decoder.statsCollector.lastDecodedFrameTime = CACurrentMediaTime()
        #expect(decoder.reserveDecodeSlot(isIDR: false) == .reserved)
        #expect(decoder.inFlightDecodeBacklog() == decoder.maxInFlightDecodes + 1)
    }

    @Test func darkDecoderDropsAtNominalBound() {
        let decoder = VideoDecoder()
        decoder.inFlightDecodes = decoder.maxInFlightDecodes
        decoder.statsCollector.lastDecodedFrameTime = CACurrentMediaTime() - 0.2
        #expect(decoder.reserveDecodeSlot(isIDR: false) == .dropAndFlush)
        #expect(decoder.inFlightDecodeBacklog() == decoder.maxInFlightDecodes)
    }

    @Test func hardCeilingDropsEvenWhileDecoderDrains() {
        let decoder = VideoDecoder()
        decoder.inFlightDecodes = decoder.maxInFlightDecodeCeiling
        decoder.statsCollector.lastDecodedFrameTime = CACurrentMediaTime()
        #expect(decoder.reserveDecodeSlot(isIDR: false) == .dropAndFlush)
        #expect(decoder.inFlightDecodeBacklog() == decoder.maxInFlightDecodeCeiling)
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
