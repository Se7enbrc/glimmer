// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import CoreMedia
import CoreVideo
import Foundation
import Testing

@testable import Glimmer

@MainActor
struct AV1SequenceHeaderTests {
    @Test func parsesSequenceHeaderWithoutDecoderModel() {
        let decoder = VideoDecoder()
        let result = decoder.parseAV1SequenceHeader(Self.sequenceHeader(decoderModel: false))

        #expect(result?.seqProfile == 1)
        #expect(result?.bitDepth == 10)
        #expect(result?.subsamplingX == 0)
        #expect(result?.subsamplingY == 0)
    }

    @Test func parsesSequenceHeaderWithDecoderModel() {
        let decoder = VideoDecoder()
        let result = decoder.parseAV1SequenceHeader(Self.sequenceHeader(decoderModel: true))

        #expect(result?.seqProfile == 1)
        #expect(result?.bitDepth == 10)
        #expect(result?.subsamplingX == 0)
        #expect(result?.subsamplingY == 0)
    }

    @Test(arguments: [false, true], [1, 16, 18])
    func colorDescriptionReachesTheFormat(fullRange: Bool, transfer: Int) throws {
        let decoder = VideoDecoder()
        decoder.streamWidth = 16
        decoder.streamHeight = 16
        let primaries = transfer == 1 ? 1 : 9
        let matrix = transfer == 1 ? 1 : 9
        let data = Self.sequenceHeader(decoderModel: false, color: (primaries, transfer, matrix),
                                       fullRange: fullRange)
        try #require(decoder.rebuildAV1FormatDescription(obuData: data))
        let format = try #require(decoder.formatDescription)
        let expectedPrimaries = transfer == 1
            ? kCVImageBufferColorPrimaries_ITU_R_709_2 : kCVImageBufferColorPrimaries_ITU_R_2020
        let expectedMatrix = transfer == 1
            ? kCVImageBufferYCbCrMatrix_ITU_R_709_2 : kCVImageBufferYCbCrMatrix_ITU_R_2020
        let expectedTransfer = transfer == 1 ? kCVImageBufferTransferFunction_ITU_R_709_2
            : (transfer == 16 ? kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
                : kCVImageBufferTransferFunction_ITU_R_2100_HLG)
        #expect(CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_ColorPrimaries)
            as? String == expectedPrimaries as String)
        #expect(CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_TransferFunction)
            as? String == expectedTransfer as String)
        #expect(CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_YCbCrMatrix)
            as? String == expectedMatrix as String)
        #expect(CMFormatDescriptionGetExtension(format, extensionKey: kCMFormatDescriptionExtension_FullRangeVideo)
            as? Bool == fullRange)
        let color = decoder.resolveColorDescription(for: try makeTaggedPixelBuffer(), controlHDR: true)
        #expect(color.primaries == expectedPrimaries as String)
        #expect(color.transfer == expectedTransfer as String)
        #expect(color.matrix == expectedMatrix as String)
        #expect(color.isHDR == (transfer != 1))
        #expect(color.range == kCVPixelFormatComponentRange_VideoRange as String)
    }

    @Test(arguments: [false, true])
    func unspecifiedColourStaysAbsent(monochrome: Bool) throws {
        let decoder = VideoDecoder()
        decoder.streamWidth = 16
        decoder.streamHeight = 16
        let data = Self.sequenceHeader(decoderModel: false, fullRange: true, profile: 0, monochrome: monochrome)
        try #require(decoder.rebuildAV1FormatDescription(obuData: data))
        let parsed = try #require(decoder.parseAV1SequenceHeader(data))
        #expect(parsed.subsamplingX == 1)
        #expect(parsed.subsamplingY == 1)
        #expect(parsed.color.fullRange)
        let format = try #require(decoder.formatDescription)
        for key in [kCMFormatDescriptionExtension_ColorPrimaries, kCMFormatDescriptionExtension_TransferFunction,
                    kCMFormatDescriptionExtension_YCbCrMatrix] {
            #expect(CMFormatDescriptionGetExtension(format, extensionKey: key) == nil)
        }
    }

    @Test func identityRGBImpliesFullRangeWithoutReadingARangeBit() throws {
        let decoder = VideoDecoder()
        let data = Self.sequenceHeader(decoderModel: false, color: (1, 13, 0))
        let parsed = try #require(decoder.parseAV1SequenceHeader(data))
        #expect(parsed.color.fullRange)
        #expect(parsed.color.primaries == 1)
        #expect(parsed.color.transfer == 13)
        #expect(parsed.color.matrix == 0)
        #expect(parsed.subsamplingX == 0)
        #expect(parsed.subsamplingY == 0)
    }

    /// A profile 1, 10-bit sequence header OBU; the fuzz suite mutates it.
    static func sequenceHeader(
        decoderModel: Bool, color: (Int, Int, Int)? = nil, fullRange: Bool = false,
        profile: Int = 1, monochrome: Bool = false
    ) -> Data {
        var bits = BitFixtureWriter()
        bits.write(profile, count: 3)
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
        bits.write(1, count: 1) // high_bitdepth
        if profile != 1 { bits.write(monochrome ? 1 : 0, count: 1) }
        bits.write(color == nil ? 0 : 1, count: 1)
        if let color {
            bits.write(color.0, count: 8)
            bits.write(color.1, count: 8)
            bits.write(color.2, count: 8)
        }
        if color?.0 != 1 || color?.1 != 13 || color?.2 != 0 || monochrome {
            bits.write(fullRange ? 1 : 0, count: 1)
            if profile == 0 && !monochrome { bits.write(0, count: 2) }
        }
        if !monochrome { bits.write(0, count: 1) } // separate_uv_delta_q
        bits.write(0, count: 1) // film_grain_params_present
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
