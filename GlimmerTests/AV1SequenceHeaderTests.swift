// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing
import VideoToolbox

@testable import GlimmerEngine
@testable import Glimmer

@MainActor
struct AV1SequenceHeaderTests {
    @Test func liveAV1SequenceChangesRefreshColourWithoutRecreatingUnchangedHeaders() async throws {
        let creates = AtomicCounter()
        let decoder = VideoDecoder(now: { 1 }, makeSession: { _, _, _, callback in
            creates.increment()
            // A software JPEG session keeps the live-session branch testable on Macs without AV1 hardware.
            // AV1 samples are rejected, but the handle stays live until the format transition invalidates it.
            var format: CMVideoFormatDescription?
            let status = CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault,
                codecType: kCMVideoCodecType_JPEG, width: 64, height: 64,
                extensions: nil, formatDescriptionOut: &format)
            guard status == noErr, let format else { return (status, nil) }
            return VideoDecoder.createSession(format, [:], [:], callback)
        })
        decoder.streamVideoFormat = StreamProtocol.VIDEO_FORMAT_AV1_MAIN10
        decoder.streamWidth = 64
        decoder.streamHeight = 64
        decoder.isStreaming = true
        decoder.hdrEnabled = true
        decoder._decodeGateLiftedAtNanos = 1
        defer { decoder.teardown() }
        let transitions = [(hdr: false, creates: 1), (hdr: true, creates: 2), (hdr: true, creates: 2)]
        for (index, transition) in transitions.enumerated() {
            let data = Self.idr(hdr: transition.hdr)
            let primaries = transition.hdr ? kCVImageBufferColorPrimaries_ITU_R_2020
                : kCVImageBufferColorPrimaries_ITU_R_709_2
            let transfer = transition.hdr ? kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
                : kCVImageBufferTransferFunction_ITU_R_709_2
            let unit = DecodeUnit(frameNumber: Int32(index + 1), frameType: StreamProtocol.FRAME_TYPE_IDR,
                fullLength: Int32(data.count), frameHostProcessingLatency: 0,
                receiveTimeUs: 0, enqueueTimeUs: 0, presentationTimeUs: 0, rtpTimestamp: UInt32(index * 1500),
                hdrActive: false, colorspace: 0, buffers: [DecodeBuffer(kind: .picData, data: data)])
            #expect(decoder.submitDecodeUnit(unit) == StreamProtocol.DR_OK)
            await decoder.decodeQueue.drainForTest()
            try decoder.decodeQueue.sync {
                try #require(decoder.decompressionSession != nil)
                let format = try #require(decoder.formatDescription)
                #expect(CMFormatDescriptionGetExtension(format,
                    extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String == transfer as String)
                let color = decoder.resolveColorDescription(for: try makeTaggedPixelBuffer(), controlHDR: true)
                #expect(color.primaries == primaries as String)
                #expect(color.transfer == transfer as String)
                #expect(color.isHDR == (index > 0))
                #expect(creates.value == transition.creates)
            }
        }
    }

    // A 64x64 black, 10-bit AV1 keyframe; only its sequence colour declaration differs.
    private static func idr(hdr: Bool) -> Data {
        let color: [UInt8] = hdr ? [0x91, 0x00, 0x90] : [0x10, 0x10, 0x10]
        return Data([0x12, 0x00, 0x0A, 0x0E, 0x02, 0x00, 0x00, 0x05, 0x15, 0x7F, 0xFC, 0x4A, 0xF9, 0x50]
            + color + [0x40, 0x32, 0x0F, 0x10, 0x00, 0xAD, 0x02, 0x07, 0x1C, 0x30, 0xC1,
                       0x00, 0x00, 0x03, 0x24, 0xFF, 0xC7, 0x80])
    }

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

    @Test func parsesPaddedCodedDimensions() throws {
        // Issue #223 reports 1920x1082 for a negotiated 1920x1080 stream.
        let decoder = VideoDecoder()
        let parsed = try #require(
            decoder.parseAV1SequenceHeader(Self.sequenceHeader(decoderModel: false,
                                                               width: 1920, height: 1082)))
        #expect(parsed.codedWidth == 1920)
        #expect(parsed.codedHeight == 1082)
    }

    @Test func parsedPaddingReachesTheFormatDescription() throws {
        let decoder = VideoDecoder()
        decoder.streamWidth = 1920
        decoder.streamHeight = 1080
        let data = Self.sequenceHeader(decoderModel: false, width: 1920, height: 1082)
        try #require(decoder.rebuildAV1FormatDescription(obuData: data))
        let dims = CMVideoFormatDescriptionGetDimensions(try #require(decoder.formatDescription))
        #expect(dims.width == 1920)
        #expect(dims.height == 1082)
    }

    @Test func headerCodingLessThanNegotiatedKeepsTheNegotiatedSize() throws {
        let decoder = VideoDecoder()
        decoder.streamWidth = 1920
        decoder.streamHeight = 1080
        let data = Self.sequenceHeader(decoderModel: false, width: 64, height: 64)
        try #require(decoder.rebuildAV1FormatDescription(obuData: data))
        let dims = CMVideoFormatDescriptionGetDimensions(try #require(decoder.formatDescription))
        #expect(dims.width == 1920)
        #expect(dims.height == 1080)
    }

    @Test(arguments: [(1920, 1082), (1936, 1096), (1920, 1080), (3840, 2160),
                      (65536, 65536), (1920, 1078), (1918, 1082), (1937, 1080)])
    func sequenceGeometryIsBounded(size: (Int, Int)) throws {
        let decoder = VideoDecoder()
        decoder.streamWidth = 1920
        decoder.streamHeight = 1080
        let data = Self.sequenceHeader(decoderModel: false, width: size.0, height: size.1)
        try #require(decoder.rebuildAV1FormatDescription(obuData: data))
        let dims = CMVideoFormatDescriptionGetDimensions(try #require(decoder.formatDescription))
        let accepted = [(1920, 1082), (1936, 1096), (1920, 1080)].contains { $0 == size }
        #expect(dims.width == (accepted ? Int32(size.0) : 1920))
        #expect(dims.height == (accepted ? Int32(size.1) : 1080))
    }

    @Test(arguments: [((1366, 768), (1408, 768), true), ((1922, 1080), (1984, 1088), true),
                      ((1281, 721), (1344, 736), true), ((1366, 768), (1407, 768), false),
                      ((1366, 768), (1472, 768), false), ((1366, 768), (1408, 784), false),
                      ((1366, 768), (1408, 767), false), ((1366, 768), (1365, 768), false)])
    func amfAlignmentRequiresTheNext64By16Boundary(size: (visible: (Int, Int), coded: (Int, Int), accepted: Bool)) throws {
        let decoder = VideoDecoder()
        decoder.streamWidth = Int32(size.visible.0)
        decoder.streamHeight = Int32(size.visible.1)
        let data = Self.sequenceHeader(decoderModel: false, width: size.coded.0, height: size.coded.1)
        try #require(decoder.rebuildAV1FormatDescription(obuData: data))
        let dimensions = CMVideoFormatDescriptionGetDimensions(try #require(decoder.formatDescription))
        #expect(dimensions.width == Int32(size.accepted ? size.coded.0 : size.visible.0))
        #expect(dimensions.height == Int32(size.accepted ? size.coded.1 : size.visible.1))
        try #require(decoder.rebuildAV1FormatDescription(obuData: Data([0x12, 0x00])))
        let rebuilt = CMVideoFormatDescriptionGetDimensions(try #require(decoder.formatDescription))
        #expect(rebuilt.width == dimensions.width)
        #expect(rebuilt.height == dimensions.height)
    }

    @Test func rebuildWithoutHeaderRetainsGeometryAndColour() throws {
        let decoder = VideoDecoder()
        decoder.streamWidth = 1920
        decoder.streamHeight = 1080
        let data = Self.sequenceHeader(decoderModel: false, color: (9, 16, 9), width: 1920, height: 1082)
        try #require(decoder.rebuildAV1FormatDescription(obuData: data))
        let header = try #require(decoder.av1SequenceHeader)
        try #require(decoder.rebuildAV1FormatDescription(obuData: Data([0x12, 0x00])))
        let format = try #require(decoder.formatDescription)
        #expect(CMVideoFormatDescriptionGetDimensions(format).height == 1082)
        #expect(decoder.av1SequenceHeader == header)
        #expect(CMFormatDescriptionGetExtension(format,
            extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String
            == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
        decoder.teardown()
        #expect(decoder.av1SequenceHeader == nil)
        #expect(decoder.av1PaddingBox.withLock { $0 } == nil)
    }

    @Test(arguments: [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                      kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange])
    func cleanApertureKeepsIOSurfaceAndTopLeftDisplayRegion(pixelFormat: OSType) throws {
        let decoder = VideoDecoder()
        decoder.streamVideoFormat = StreamProtocol.VIDEO_FORMAT_AV1_MAIN10
        decoder.streamWidth = 32
        decoder.streamHeight = 16
        try #require(decoder.rebuildAV1FormatDescription(
            obuData: Self.sequenceHeader(decoderModel: false, width: 34, height: 18)))
        var created: CVPixelBuffer?
        try #require(CVPixelBufferCreate(kCFAllocatorDefault, 34, 18, pixelFormat,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &created) == kCVReturnSuccess)
        let padded = try #require(created)
        let surface = try #require(CVPixelBufferGetIOSurface(padded)?.takeUnretainedValue())
        CVBufferSetAttachment(padded, kCVImageBufferColorPrimariesKey,
                              kCVImageBufferColorPrimaries_ITU_R_2020, .shouldPropagate)
        CVBufferSetAttachment(padded, kCVImageBufferPreferredCleanApertureKey,
            [kCVImageBufferCleanApertureWidthKey: 34, kCVImageBufferCleanApertureHeightKey: 18]
                as CFDictionary, .shouldPropagate)
        CVBufferSetAttachment(padded, kCVImageBufferDisplayDimensionsKey,
            [kCVImageBufferDisplayWidthKey: 34, kCVImageBufferDisplayHeightKey: 18]
                as CFDictionary, .shouldPropagate)
        decoder.attach(to: AVSampleBufferDisplayLayer())
        decoder.isStreaming = true
        defer { decoder.teardown() }
        decoder.enqueueDecodedFrame(padded, hostPTS: CMTime(value: 1, timescale: 60))
        #expect(CVPixelBufferGetIOSurface(padded)?.takeUnretainedValue() === surface)
        #expect(CVBufferCopyAttachment(padded, kCVImageBufferPreferredCleanApertureKey, nil) == nil)
        #expect(CVBufferCopyAttachment(padded, kCVImageBufferDisplayDimensionsKey, nil) == nil)
        #expect(CVPixelBufferGetWidth(padded) == 34)
        #expect(CVPixelBufferGetHeight(padded) == 18)
        let description = try #require(decoder.cachedHDRFormatDescription)
        #expect(CMVideoFormatDescriptionGetCleanAperture(description, originIsAtTopLeft: true)
            == CGRect(x: 0, y: 0, width: 32, height: 16))
        #expect(CMVideoFormatDescriptionMatchesImageBuffer(description, imageBuffer: padded))
        #expect(CMFormatDescriptionGetExtension(description,
            extensionKey: kCMFormatDescriptionExtension_ColorPrimaries) as? String
            == kCVImageBufferColorPrimaries_ITU_R_2020 as String)
    }

    @Test(arguments: [StreamProtocol.VIDEO_FORMAT_H264, StreamProtocol.VIDEO_FORMAT_H265,
                      StreamProtocol.VIDEO_FORMAT_AV1_MAIN8], [(32, 18), (64, 36), (32, 16)])
    func apertureOnlyAppliesToMatchingAV1Padding(codec: Int32, size: (Int, Int)) throws {
        let decoder = VideoDecoder()
        decoder.streamVideoFormat = codec
        decoder.streamWidth = 32
        decoder.streamHeight = 16
        try #require(decoder.rebuildAV1FormatDescription(
            obuData: Self.sequenceHeader(decoderModel: false, width: 32, height: 18)))
        var created: CVPixelBuffer?
        try #require(CVPixelBufferCreate(kCFAllocatorDefault, size.0, size.1,
            kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &created) == kCVReturnSuccess)
        let buffer = try #require(created)
        decoder.applyAV1CleanAperture(to: buffer)
        let attachment = CVBufferCopyAttachment(buffer, kCVImageBufferCleanApertureKey, nil)
        #expect((attachment != nil) == (codec == StreamProtocol.VIDEO_FORMAT_AV1_MAIN8 && size == (32, 18)))
    }

    @Test(arguments: [kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                      kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange])
    func amfWidthPaddingKeepsTheTopLeftVisibleRegion(pixelFormat: OSType) throws {
        let decoder = VideoDecoder()
        decoder.streamVideoFormat = StreamProtocol.VIDEO_FORMAT_AV1_MAIN10
        decoder.streamWidth = 1366
        decoder.streamHeight = 768
        try #require(decoder.rebuildAV1FormatDescription(
            obuData: Self.sequenceHeader(decoderModel: false, width: 1408, height: 768)))
        var created: CVPixelBuffer?
        try #require(CVPixelBufferCreate(kCFAllocatorDefault, 1408, 768, pixelFormat,
            [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary, &created) == kCVReturnSuccess)
        let buffer = try #require(created)
        let surface = try #require(CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue())
        decoder.applyAV1CleanAperture(to: buffer)
        var format: CMVideoFormatDescription?
        try #require(CMVideoFormatDescriptionCreateForImageBuffer(allocator: kCFAllocatorDefault,
            imageBuffer: buffer, formatDescriptionOut: &format) == noErr)
        #expect(CMVideoFormatDescriptionGetCleanAperture(try #require(format), originIsAtTopLeft: true)
            == CGRect(x: 0, y: 0, width: 1366, height: 768))
        #expect(CVPixelBufferGetIOSurface(buffer)?.takeUnretainedValue() === surface)
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
        profile: Int = 1, monochrome: Bool = false,
        width: Int = 1, height: Int = 1
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
        // frame_width_bits_minus_1 / max_frame_width_minus_1 pairs sized to
        // the requested coded dimensions (defaults keep the historic 1x1).
        let widthFieldBits = Self.bitWidth(width - 1)
        let heightFieldBits = Self.bitWidth(height - 1)
        bits.write(widthFieldBits - 1, count: 4)
        bits.write(heightFieldBits - 1, count: 4)
        bits.write(width - 1, count: widthFieldBits)
        bits.write(height - 1, count: heightFieldBits)
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

    /// Bits needed to hold `value`, floored at 1 so minus_1 fields stay legal.
    private static func bitWidth(_ value: Int) -> Int {
        var remaining = value
        var bits = 0
        while remaining > 0 {
            bits += 1
            remaining >>= 1
        }
        return max(bits, 1)
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
