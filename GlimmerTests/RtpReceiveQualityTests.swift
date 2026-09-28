import Testing
@testable import Glimmer

struct RtpReceiveQualityTests {
    private let delegate = RecordingDepacketizerDelegate()
    private func queue() -> RtpVideoQueue {
        RtpVideoQueue(depacketizer: VideoDepacketizer(
            delegate: delegate, negotiatedVideoFormat: StreamProtocol.VIDEO_FORMAT_AV1_MAIN8, colorSpace: 0),
            packetSize: 64)
    }

    private func receive(_ queue: RtpVideoQueue, seq: UInt16, frame: UInt32, at time: UInt64,
                         timestamp: UInt32? = nil) {
        let ticks = timestamp ?? UInt32(truncatingIfNeeded: time * 90 / 1_000)
        var bytes = [UInt8](repeating: 0, count: 40)
        bytes[0] = RtpVideoQueue.FLAG_EXTENSION
        bytes[2] = UInt8(seq >> 8)
        bytes[3] = UInt8(truncatingIfNeeded: seq)
        for index in 0..<4 {
            bytes[4 + index] = UInt8(truncatingIfNeeded: ticks >> (24 - index * 8))
            bytes[20 + index] = UInt8(truncatingIfNeeded: frame >> (index * 8))
        }
        bytes[24] = RtpVideoQueue.FLAG_SOF | RtpVideoQueue.FLAG_CONTAINS_PIC_DATA
        bytes[30] = 0xC0
        queue.addRawDatagram(bytes, receiveTimeUs: time)
    }

    @Test(arguments: [UInt16(40_000), UInt16(0)])
    func newerFrameReseedsAliasedSequence(sequence: UInt16) {
        let queue = queue()
        receive(queue, seq: 0, frame: 1, at: 1_000)
        receive(queue, seq: 1, frame: 1, at: 2_000)
        receive(queue, seq: sequence, frame: 2, at: 3_002_000)
        #expect(queue.currentFrameNumber == 2)
        #expect(queue.seqHighestSeen == sequence)
        #expect(queue.pending.map(\.sequenceNumber) == [sequence])
        #expect(queue.windowDuplicate == 0)
        #expect(queue.windowOutOfOrder == 0)
        #expect(queue.windowLostPreFec == 0)
        #expect(queue.pendingReorderCredit == 0)
    }

    @Test(arguments: [UInt16(999), UInt16(100)])
    func staleArrivalPreservesBlackoutEligibility(stale: UInt16) {
        let queue = queue()
        for seq in UInt16(100)...1_000 { receive(queue, seq: seq, frame: 1, at: UInt64(seq)) }
        receive(queue, seq: stale, frame: 1, at: 3_001_000)
        #expect(queue.seqHighestSeen == 1_000)
        #expect(queue.hasRecentSequence(999))
        receive(queue, seq: 41_000, frame: 2, at: 3_001_001)
        #expect(queue.seqHighestSeen == 41_000)
        #expect(queue.currentFrameNumber == 2)
        #expect(queue.pendingReorderCredit == 0)
        #expect(!queue.haveOpenGap)
        let reorders = queue.windowOutOfOrder
        for seq in UInt16(41_001)...41_100 { receive(queue, seq: seq, frame: 2, at: 3_002_000 + UInt64(seq)) }
        #expect(queue.windowOutOfOrder == reorders)
        #expect(queue.windowLostPreFec == 0)
    }

    @Test(arguments: [UInt16(999), UInt16(100)])
    func staleArrivalDoesNotResetBaseline(stale: UInt16) {
        let queue = queue()
        for seq in UInt16(100)...1_000 { receive(queue, seq: seq, frame: 2, at: UInt64(seq)) }
        receive(queue, seq: stale, frame: 1, at: 1_002_000)
        #expect(queue.seqHighestSeen == 1_000)
        #expect(queue.hasRecentSequence(999))
        receive(queue, seq: 1_001, frame: 2, at: 1_002_001)
        #expect(queue.windowLostPreFec == 0)
    }

    @Test(arguments: [UInt32(2), UInt32(0)])
    func olderFrameForwardAliasPreservesBlackoutEligibility(frame: UInt32) {
        let queue = queue()
        receive(queue, seq: 1_000, frame: frame, at: 1_000)
        receive(queue, seq: 2_000, frame: frame &- 1, at: 1_002_000)
        #expect(queue.seqHighestSeen == 1_000)
        #expect(queue.seqNewestFrame == frame)
        #expect(queue.sequenceBlackoutEligible)
        #expect(queue.windowLostPreFec == 0)
        #expect(!queue.haveOpenGap)

        receive(queue, seq: 41_000, frame: frame &+ 1, at: 1_002_001)
        #expect(queue.seqHighestSeen == 41_000)
        #expect(queue.seqNewestFrame == frame &+ 1)
        #expect(!queue.sequenceBlackoutEligible)
        #expect(queue.pendingReorderCredit == 0)
        #expect(queue.windowLostPreFec == 0)
        #expect(!queue.haveOpenGap)
    }

    @Test(arguments: [UInt32(2), UInt32(0)], [UInt16(100), UInt16(2_000)])
    func olderFrameCannotCancelLaterLoss(frame: UInt32, sequence: UInt16) {
        let queue = queue()
        receive(queue, seq: 1_000, frame: frame, at: 1_000)
        receive(queue, seq: sequence, frame: frame &- 1, at: 1_002_000)
        #expect(queue.windowOutOfOrder == 0)
        #expect(queue.pendingReorderCredit == 0)
        #expect(queue.seqHighestSeen == 1_000)
        #expect(!queue.hasRecentSequence(sequence))

        receive(queue, seq: 1_002, frame: frame &+ 1, at: 1_002_001)
        #expect(queue.windowLostPreFec == 1)
        #expect(queue.applyPendingReorderCredit() == 1)
        #expect(queue.seqHighestSeen == 1_002)
    }

    @Test func duplicateHistorySurvivesMetricFlush() {
        let queue = queue()
        receive(queue, seq: 10, frame: 1, at: 1_000)
        receive(queue, seq: 12, frame: 1, at: 2_000)
        receive(queue, seq: 10, frame: 1, at: 2_002_000)
        #expect(queue.windowDuplicate == 0)
        receive(queue, seq: 10, frame: 1, at: 2_002_001)
        #expect(queue.windowDuplicate == 1)
        #expect(queue.windowOutOfOrder == 0)
        #expect(queue.pendingReorderCredit == 0)
        receive(queue, seq: 14, frame: 1, at: 2_003_000)
        #expect(queue.applyPendingReorderCredit() == 1)
    }

    @Test(arguments: [UInt16(14), UInt16(10), UInt16(11)])
    func boundaryPacketQualityFlushesWithItsPacketCount(sequence: UInt16) {
        let queue = queue()
        receive(queue, seq: 10, frame: 1, at: 1_000)
        receive(queue, seq: 12, frame: 1, at: 2_000_999)
        #expect(queue.packetsInWindow == 2)
        #expect(queue.windowLostPreFec == 1)
        #expect(queue.gapCount == 1)

        receive(queue, seq: sequence, frame: 1, at: 2_001_000)
        #expect(queue.metricsWindowStartUs == 2_001_000)
        #expect(queue.packetsInWindow == 0)
        #expect(queue.windowLostPreFec == 0)
        #expect(queue.windowDuplicate == 0)
        #expect(queue.windowOutOfOrder == 0)
        #expect(queue.pendingReorderCredit == 0)
        #expect(queue.gapCount == 0)
        #expect(queue.gapMaxUs == 0)
        #expect(queue.gapBuckets.allSatisfy { $0 == 0 })
    }

    @Test func ringEvictsOnlyTheOldestAndHandlesSequenceWrap() {
        let queue = queue()
        for offset in 0..<513 { queue.rememberSeq(UInt16.max &+ UInt16(offset)) }
        #expect(!queue.hasRecentSequence(UInt16.max))
        #expect(queue.hasRecentSequence(0))
        #expect(queue.hasRecentSequence(511))
        #expect(queue.recentSeqCount == 512)
        let head = queue.recentSeqHead
        queue.rememberSeq(0)
        #expect(queue.recentSeqHead == head)
    }

    @Test func timestampWrapKeepsSteadyJitter() {
        let queue = queue()
        receive(queue, seq: 0, frame: 1, at: 1_000, timestamp: UInt32.max - 44)
        receive(queue, seq: 1, frame: 1, at: 2_000, timestamp: 45)
        #expect(queue.jitterUs < 1_000)
    }

    @Test func forwardJumpAfterBlackoutStillCountsLoss() {
        let queue = queue()
        receive(queue, seq: 0, frame: 1, at: 1_000)
        receive(queue, seq: 100, frame: 2, at: 1_002_000)
        #expect(queue.windowLostPreFec == 99)
    }
}
