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

    /// Every metadata prefix (none, AUD, SEI, AUD+SEI+SEI) with each start-code length.
    static let keyFrameShapes = [0, 1, 2, 3].flatMap { prefix in [3, 4].map { (prefix: prefix, startLength: $0) } }

    @Test(arguments: [false, true], keyFrameShapes)
    func annexBKeyFramesOpenRecoveryGate(hevc: Bool, shape: (prefix: Int, startLength: Int)) throws {
        let recorder = RecordingDepacketizerDelegate()
        let dp = VideoDepacketizer(delegate: recorder, negotiatedVideoFormat: hevc
            ? StreamProtocol.VIDEO_FORMAT_H265 : StreamProtocol.VIDEO_FORMAT_H264, colorSpace: 0)
        let start = [UInt8](repeating: 0, count: shape.startLength - 1) + [1]
        let aud = start + (hevc ? [UInt8(0x46), 1, 0x50] : [0x09, 0x10])
        let sei = start + (hevc ? [UInt8(0x4E), 1, 0x80] : [0x06, 0x80])
        let metadata: [UInt8]
        switch shape.prefix {
        case 1: metadata = aud
        case 2: metadata = sei
        case 3: metadata = aud + sei + sei
        default: metadata = []
        }
        let sps = start + (hevc ? [UInt8(0x42), 1, 0x20] : [0x67, 0x20])
        let pps = start + (hevc ? [UInt8(0x44), 1, 0x30] : [0x68, 0x30])
        let vps = hevc ? start + [UInt8(0x40), 1, 0x10] : []
        let slice = start + (hevc ? [UInt8(0x26), 1, 0x40] : [0x65, 0x40])
        let body = metadata + vps + sps + pps + slice
        dp.process(packet(frame: 1, spi: 0, type: 2, body: body))
        let first = try #require(recorder.units.first)
        #expect(first.frameType == StreamProtocol.FRAME_TYPE_IDR)
        #expect(first.buffers.first { $0.kind == .sps }?.data == Data(sps))
        #expect(first.buffers.first { $0.kind == .pps }?.data == Data(pps))
        #expect(first.buffers.first { $0.kind == .picData }?.data == Data(metadata + slice))
        if hevc { #expect(first.buffers.first { $0.kind == .vps }?.data == Data(vps)) }
        dp.requestDecoderRefresh()
        dp.process(packet(frame: 2, spi: 1, type: 1, body: metadata + slice))
        #expect(recorder.units.map(\.frameNumber) == [1])
        dp.process(packet(frame: 3, spi: 2, type: 2, body: body))
        #expect(recorder.units.map(\.frameNumber) == [1, 3])
        #expect(recorder.keyFrames == [1, 3])
        #expect(recorder.idrRequests == 1)
    }

    @Test(arguments: [false, true])
    func annexBMetadataCannotOpenGateWithoutParameterSets(hevc: Bool) {
        let recorder = RecordingDepacketizerDelegate()
        let dp = VideoDepacketizer(delegate: recorder, negotiatedVideoFormat: hevc
            ? StreamProtocol.VIDEO_FORMAT_H265 : StreamProtocol.VIDEO_FORMAT_H264, colorSpace: 0)
        let aud: [UInt8] = [0, 0, 0, 1] + (hevc ? [0x46, 1, 0x50] : [0x09, 0x10])
        let sei: [UInt8] = [0, 0, 1] + (hevc ? [0x4E, 1, 0x80] : [0x06, 0x80])
        let slice: [UInt8] = [0, 0, 1] + (hevc ? [0x02, 1, 0x40] : [0x41, 0x40])
        let bodies = [aud, aud + sei, aud + sei + [0, 0, 0, 1], aud + sei + slice]
        for (index, body) in bodies.enumerated() {
            let frame = UInt32(index + 1)
            dp.process(packet(frame: frame, spi: UInt32(index), type: 2, body: body))
        }
        #expect(recorder.units.isEmpty)
        #expect(recorder.keyFrames.isEmpty)
    }
}
