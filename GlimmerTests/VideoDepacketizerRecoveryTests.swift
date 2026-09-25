import Foundation
import Testing
@testable import Glimmer

final class RecordingDepacketizerDelegate: VideoDepacketizerDelegate {
    var units: [DecodeUnit] = []
    var losses: [(from: Int, to: Int)] = []
    var idrRequests = 0
    var keyFrames: [Int] = []

    func depacketizerDidAssembleFrame(_ unit: DecodeUnit) { units.append(unit) }
    func depacketizerDetectedFrameLoss(from: Int, to: Int) { losses.append((from, to)) }
    func depacketizerNeedsIdr() { idrRequests += 1 }
    func depacketizerReceivedKeyFrame(frameNumber: Int) { keyFrames.append(frameNumber) }
}

struct VideoDepacketizerRecoveryTests {
    private func depacketizer(_ recorder: RecordingDepacketizerDelegate) -> VideoDepacketizer {
        VideoDepacketizer(delegate: recorder,
                          negotiatedVideoFormat: StreamProtocol.VIDEO_FORMAT_AV1_MAIN8,
                          colorSpace: 0)
    }

    private func packet(frame: UInt32, spi: UInt32, type: UInt8, body: [UInt8] = [0x31],
                        length: Int? = nil, flags: UInt8 = 0x07) -> VideoDepacketizer.CompletedPacket {
        let payloadLength = length ?? body.count + 8
        let header: [UInt8] = [1, 0, 0, type,
                               UInt8(truncatingIfNeeded: payloadLength),
                               UInt8(truncatingIfNeeded: payloadLength >> 8), 0, 0]
        return VideoDepacketizer.CompletedPacket(
            frameIndex: frame, flags: flags, extraFlags: 0, fecCurrentBlock: 0, fecLastBlock: 0,
            streamPacketIndex: spi << 8, rtpTimestamp: frame,
            presentationTimeUs: UInt64(frame) * 1_000, receiveTimeUs: UInt64(frame) * 1_000,
            payload: header + body)
    }

    @Test func rfiWaitDropsPFramesUntilRecoveryFrame() {
        let recorder = RecordingDepacketizerDelegate()
        let dp = depacketizer(recorder)
        dp.process(packet(frame: 1, spi: 0, type: 2))
        dp.queueLostFrame(2)
        dp.process(packet(frame: 3, spi: 1, type: 1))
        dp.process(packet(frame: 4, spi: 2, type: 1))
        #expect(recorder.losses.map(\.to) == [2, 3, 4])
        #expect(recorder.units.map(\.frameNumber) == [1])
        dp.process(packet(frame: 5, spi: 3, type: 4))
        #expect(recorder.units.map(\.frameNumber) == [1, 5])
        #expect(recorder.idrRequests == 0)
    }

    @Test func idrAlsoReopensRfiWait() {
        let recorder = RecordingDepacketizerDelegate()
        let dp = depacketizer(recorder)
        dp.process(packet(frame: 1, spi: 0, type: 2))
        dp.queueLostFrame(2)
        dp.process(packet(frame: 3, spi: 1, type: 2))
        #expect(recorder.units.map(\.frameNumber) == [1, 3])
        #expect(recorder.keyFrames == [1, 3])
    }

    @Test func lastAv1PacketIsTruncatedToAdvertisedLength() throws {
        let recorder = RecordingDepacketizerDelegate()
        let dp = depacketizer(recorder)
        dp.process(packet(frame: 1, spi: 0, type: 2, body: [0x11, 0x12], length: 2, flags: 0x05))
        dp.process(VideoDepacketizer.CompletedPacket(
            frameIndex: 1, flags: 0x03, extraFlags: 0, fecCurrentBlock: 0, fecLastBlock: 0,
            streamPacketIndex: 1 << 8, rtpTimestamp: 1, presentationTimeUs: 1_000,
            receiveTimeUs: 1_000, payload: [0x21, 0x22, 0, 0]))
        let unit = try #require(recorder.units.first)
        #expect(unit.buffers.first?.data == Data([0x11, 0x12, 0x21, 0x22]))
    }

    @Test func oversizedLastPayloadIsDroppedAndReported() {
        let recorder = RecordingDepacketizerDelegate()
        let dp = depacketizer(recorder)
        dp.process(packet(frame: 1, spi: 0, type: 2))
        dp.process(packet(frame: 2, spi: 1, type: 1, length: 20))
        #expect(recorder.units.map(\.frameNumber) == [1])
        #expect(recorder.losses.map(\.to) == [2])
    }

    @Test func spiGapRequestsIdrBeforeFirstKeyFrameAndRfiAfterIt() {
        let before = RecordingDepacketizerDelegate()
        let first = depacketizer(before)
        first.process(packet(frame: 1, spi: 1, type: 1, flags: 0x03))
        #expect(before.idrRequests == 1)

        let after = RecordingDepacketizerDelegate()
        let second = depacketizer(after)
        second.process(packet(frame: 1, spi: 0, type: 2))
        second.process(packet(frame: 2, spi: 2, type: 1, flags: 0x03))
        #expect(after.losses.map(\.to) == [2])
        #expect(after.idrRequests == 0)
    }

    @Test func sustainedDropsForceOneIdrAtTheLimit() {
        let recorder = RecordingDepacketizerDelegate()
        let dp = depacketizer(recorder)
        dp.process(packet(frame: 1, spi: 0, type: 2))
        for frame in 2...121 { dp.queueLostFrame(frame) }
        #expect(recorder.idrRequests == 1)
        #expect(recorder.losses.count == 119)
    }
}
