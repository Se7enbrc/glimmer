import Foundation
import Testing

@testable import Glimmer

@MainActor
struct AV1SequenceHeaderTests {
    @Test func parsesSequenceHeaderWithoutDecoderModel() {
        let decoder = VideoDecoder()
        let result = decoder.parseAV1SequenceHeader(sequenceHeader(decoderModel: false))

        #expect(result?.seqProfile == 1)
        #expect(result?.bitDepth == 10)
        #expect(result?.subsamplingX == 0)
        #expect(result?.subsamplingY == 0)
    }

    @Test func parsesSequenceHeaderWithDecoderModel() {
        let decoder = VideoDecoder()
        let result = decoder.parseAV1SequenceHeader(sequenceHeader(decoderModel: true))

        #expect(result?.seqProfile == 1)
        #expect(result?.bitDepth == 10)
        #expect(result?.subsamplingX == 0)
        #expect(result?.subsamplingY == 0)
    }

    private func sequenceHeader(decoderModel: Bool) -> Data {
        var bits = BitFixtureWriter()
        bits.write(1, count: 3)
        bits.write(0, count: 1)
        bits.write(0, count: 1)
        bits.write(1, count: 1)
        bits.write(0, count: 32)
        bits.write(0, count: 32)
        bits.write(0, count: 1)
        bits.write(decoderModel ? 1 : 0, count: 1)
        if decoderModel {
            bits.write(4, count: 5)
            bits.write(0, count: 32)
            bits.write(0, count: 5)
            bits.write(0, count: 5)
        }
        bits.write(0, count: 1)
        bits.write(0, count: 5)
        bits.write(0, count: 12)
        bits.write(0, count: 5)
        if decoderModel {
            bits.write(1, count: 1)
            bits.write(0, count: 5)
            bits.write(0, count: 5)
            bits.write(0, count: 1)
        }
        bits.write(0, count: 4)
        bits.write(0, count: 4)
        bits.write(0, count: 1)
        bits.write(0, count: 1)
        bits.write(0, count: 1)
        bits.write(0, count: 1)
        bits.write(0, count: 1)
        bits.write(0, count: 1)
        bits.write(0, count: 1)
        bits.write(0, count: 1)
        bits.write(0, count: 1)
        bits.write(0, count: 1)
        bits.write(0, count: 1)
        bits.write(0, count: 1)
        bits.write(0, count: 1)
        bits.write(1, count: 1)
        bits.write(0, count: 1)
        bits.write(0, count: 1)
        bits.write(1, count: 1)
        bits.write(0, count: 1)
        bits.write(0, count: 1)
        bits.write(0, count: 1)
        bits.write(0, count: 1)
        bits.write(0, count: 1)
        return Data([0x0A, UInt8(bits.bytes.count)] + bits.bytes)
    }
}

private struct BitFixtureWriter {
    private(set) var bytes: [UInt8] = []
    private var offset = 0

    mutating func write(_ value: Int, count: Int) {
        for bit in (0..<count).reversed() {
            if offset == 0 { bytes.append(0) }
            if value & (1 << bit) != 0 {
                bytes[bytes.count - 1] |= 1 << (7 - offset)
            }
            offset = (offset + 1) % 8
        }
    }
}
