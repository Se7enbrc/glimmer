//
//  AnnexBToAVCCTests.swift
//
//  Covers VideoDecoder.convertAnnexBToAVCC - the Annex-B start-code -> AVCC
//  4-byte-length-prefix rewrite VideoToolbox H.264/HEVC consume. Pure transform
//  of one AU; reads no decoder state, so it's exercisable off a bare instance.
//

import Foundation
import Testing

@testable import Glimmer

// VideoDecoder.init() is MainActor-isolated; convertAnnexBToAVCC itself is
// nonisolated and pure, so the test just builds the instance on the main actor.
@MainActor
struct AnnexBToAVCCTests {

    /// Read the 4-byte big-endian length prefix at `offset`.
    private func len32(_ data: Data, at offset: Int) -> Int {
        Int(data[offset]) << 24 | Int(data[offset + 1]) << 16
            | Int(data[offset + 2]) << 8 | Int(data[offset + 3])
    }

    @Test func singleNalFourByteStartCode() {
        let decoder = VideoDecoder()
        let input = Data([0, 0, 0, 1, 0x65, 0xAA, 0xBB])
        let out = decoder.convertAnnexBToAVCC(input)
        // 4-byte length prefix (3) + the 3 NAL payload bytes.
        #expect(out.count == 7)
        #expect(len32(out, at: 0) == 3)
        #expect(Array(out[4...]) == [0x65, 0xAA, 0xBB])
    }

    @Test func singleNalThreeByteStartCode() {
        let decoder = VideoDecoder()
        let input = Data([0, 0, 1, 0x41, 0x10])
        let out = decoder.convertAnnexBToAVCC(input)
        #expect(out.count == 6)
        #expect(len32(out, at: 0) == 2)
        #expect(Array(out[4...]) == [0x41, 0x10])
    }

    @Test func multipleNalsMixedStartCodes() {
        let decoder = VideoDecoder()
        // SPS (4-byte SC, 2 bytes) then PPS (3-byte SC, 1 byte).
        let input = Data([0, 0, 0, 1, 0x67, 0x42, 0, 0, 1, 0x68])
        let out = decoder.convertAnnexBToAVCC(input)
        #expect(out.count == 4 + 2 + 4 + 1)
        #expect(len32(out, at: 0) == 2)
        #expect(Array(out[4..<6]) == [0x67, 0x42])
        #expect(len32(out, at: 6) == 1)
        #expect(Array(out[10...]) == [0x68])
    }

    @Test func emptyNalBetweenStartCodesSkipped() {
        let decoder = VideoDecoder()
        // Back-to-back start codes leave a zero-length unit - it must be dropped
        // so VT never sees a 0-length NAL.
        let input = Data([0, 0, 0, 1, 0, 0, 0, 1, 0x65])
        let out = decoder.convertAnnexBToAVCC(input)
        #expect(out.count == 4 + 1)
        #expect(len32(out, at: 0) == 1)
        #expect(Array(out[4...]) == [0x65])
    }

    @Test func noStartCodePassesNothing() {
        let decoder = VideoDecoder()
        // No leading start code -> nothing is treated as a NAL.
        let input = Data([0x65, 0xAA])
        let out = decoder.convertAnnexBToAVCC(input)
        #expect(out.isEmpty)
    }

    @Test func emptyInputYieldsEmpty() {
        let decoder = VideoDecoder()
        #expect(decoder.convertAnnexBToAVCC(Data()).isEmpty)
    }
}
