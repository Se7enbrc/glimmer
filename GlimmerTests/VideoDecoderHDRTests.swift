// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  VideoDecoderHDRTests.swift
//
//  Which colorspace a decoded frame is tagged with, the HDR10 metadata blobs, and the layer's HDR mode.
//

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import Glimmer

/// An IOSurface-backed frame carrying the colour tags VT would copy from the bitstream.
func makeTaggedPixelBuffer(
    primaries: CFString? = nil, transfer: CFString? = nil, width: Int = 16, height: Int = 16,
    format: OSType = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
) throws -> CVPixelBuffer {
    var image: CVPixelBuffer?
    let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
    try #require(CVPixelBufferCreate(nil, width, height, format, attributes, &image) == kCVReturnSuccess)
    let buffer = try #require(image)
    if let primaries {
        CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
    }
    if let transfer {
        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)
    }
    return buffer
}

/// Sunshine's usual HDR10 static metadata, in SS_HDR_METADATA's RGB order and units.
let sampleHostHDR = HdrMetadata(
    displayPrimariesRX: 35_400, displayPrimariesRY: 14_600,
    displayPrimariesGX: 8_500, displayPrimariesGY: 39_850,
    displayPrimariesBX: 6_550, displayPrimariesBY: 2_300,
    whitePointX: 15_635, whitePointY: 16_450,
    maxDisplayLuminance: 1_000, minDisplayLuminance: 50,
    maxContentLightLevel: 1_000, maxFrameAverageLightLevel: 400,
    maxFullFrameLuminance: 0)

@MainActor
struct VideoDecoderHDRTests {

    struct ColorCase: Sendable, CustomTestStringConvertible {
        let format: Int32
        let hostHDR: Bool
        let primaries: String?
        let transfer: String?
        let key: String
        var testDescription: String { "\(String(format, radix: 16)) hdr=\(hostHDR) \(primaries ?? "-") → \(key)" }
    }

    nonisolated static let main10 = StreamProtocol.VIDEO_FORMAT_H265_MAIN10
    nonisolated static let main8 = StreamProtocol.VIDEO_FORMAT_H265
    nonisolated static let bt2020 = kCVImageBufferColorPrimaries_ITU_R_2020 as String
    nonisolated static let bt709 = kCVImageBufferColorPrimaries_ITU_R_709_2 as String
    nonisolated static let pq = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String
    nonisolated static let p3 = kCVImageBufferColorPrimaries_P3_D65 as String

    nonisolated static let colorCases: [ColorCase] = [
        // Sunshine tags Main10 PQ as BT.709 on some GPUs: the PC's HDR signal wins.
        ColorCase(format: main10, hostHDR: true, primaries: bt709, transfer: nil, key: "itur_2100_PQ"),
        ColorCase(format: main10, hostHDR: true, primaries: nil, transfer: nil, key: "itur_2100_PQ"),
        ColorCase(format: main10, hostHDR: false, primaries: bt2020, transfer: pq, key: "itur_2100_PQ"),
        ColorCase(format: main10, hostHDR: false, primaries: bt2020, transfer: nil, key: "itur_2020"),
        ColorCase(format: main10, hostHDR: false, primaries: bt709, transfer: nil, key: "itur_709"),
        ColorCase(format: main10, hostHDR: false, primaries: p3, transfer: nil, key: "itur_2020"),
        ColorCase(format: main10, hostHDR: false, primaries: nil, transfer: nil, key: "itur_2020"),
        ColorCase(format: main8, hostHDR: true, primaries: nil, transfer: nil, key: "itur_709"),
        ColorCase(format: main8, hostHDR: false, primaries: p3, transfer: nil, key: "itur_709"),
        ColorCase(format: main8, hostHDR: false, primaries: bt2020, transfer: pq, key: "itur_2100_PQ")
    ]

    @Test(arguments: colorCases)
    func derivedKeyFollowsTagsAndThePCsHDRSignal(_ testCase: ColorCase) throws {
        let decoder = VideoDecoder()
        decoder.streamVideoFormat = testCase.format
        decoder.hdrEnabled = testCase.hostHDR
        let buffer = try makeTaggedPixelBuffer(
            primaries: testCase.primaries.map { $0 as CFString }, transfer: testCase.transfer.map { $0 as CFString })
        #expect(decoder.derivedColorSpaceKey(for: buffer) == testCase.key)
    }

    @Test func eachKeyBuildsItsNamedColorSpace() {
        let decoder = VideoDecoder()
        let expected: [String: CFString] = [
            "itur_2100_PQ": CGColorSpace.itur_2100_PQ, "itur_2020": CGColorSpace.itur_2020,
            "itur_709": CGColorSpace.itur_709, "srgb": CGColorSpace.sRGB, "unknown": CGColorSpace.itur_709
        ]
        for (key, name) in expected {
            #expect(decoder.makeCGColorSpace(forKey: key)?.name == name, "\(key)")
        }
    }

    // MARK: HDR10 metadata blobs

    @Test func hostMetadataBecomesBigEndianGBRBlobs() {
        let decoder = VideoDecoder()
        let backend = InputRecordingBackend()
        backend.hdr = sampleHostHDR
        decoder.setBackend(backend)
        decoder.refreshHDRMetadataFromHost()

        let metadata = decoder.hdrMetadataStore.snapshot
        let mdcv: [UInt8] = [
            0x21, 0x34, 0x9B, 0xAA,  // green
            0x19, 0x96, 0x08, 0xFC,  // blue
            0x8A, 0x48, 0x39, 0x08,  // red
            0x3D, 0x13, 0x40, 0x42,  // white point
            0x00, 0x98, 0x96, 0x80,  // 1000 nits in 0.0001-nit units
            0x00, 0x00, 0x00, 0x32   // min luminance passes through
        ]
        #expect(metadata.mdcv == Data(mdcv))
        #expect(metadata.contentLightLevel == Data([0x03, 0xE8, 0x01, 0x90]))
    }

    @Test func missingPrimariesOrLightLevelsLeaveThatBlobOut() {
        let decoder = VideoDecoder()
        let backend = InputRecordingBackend()
        var noPrimaries = sampleHostHDR
        noPrimaries.displayPrimariesRX = 0
        backend.hdr = noPrimaries
        decoder.setBackend(backend)
        decoder.refreshHDRMetadataFromHost()
        #expect(decoder.hdrMetadataStore.snapshot.mdcv == nil)
        #expect(decoder.hdrMetadataStore.snapshot.contentLightLevel?.count == 4)

        var noFrameAverage = sampleHostHDR
        noFrameAverage.maxFrameAverageLightLevel = 0
        backend.hdr = noFrameAverage
        decoder.refreshHDRMetadataFromHost()
        #expect(decoder.hdrMetadataStore.snapshot.mdcv?.count == 24)
        #expect(decoder.hdrMetadataStore.snapshot.contentLightLevel == nil)
    }

    @Test func noMetadataFromThePCClearsTheStore() {
        let decoder = VideoDecoder()
        decoder.hdrMetadataStore.publish(HDRMetadata(mdcv: Data([1]), contentLightLevel: Data([2])))
        decoder.setBackend(InputRecordingBackend())
        decoder.refreshHDRMetadataFromHost()
        #expect(decoder.hdrMetadataStore.snapshot == .empty)
    }

    // MARK: Layer HDR mode

    @Test func tenBitHDRStreamEngagesTheLayerAndBackOff() {
        let decoder = VideoDecoder()
        let layer = AVSampleBufferDisplayLayer()
        decoder.attach(to: layer)
        defer { decoder.teardown() }
        let backend = InputRecordingBackend()
        backend.hdr = sampleHostHDR
        decoder.setBackend(backend)
        decoder.streamVideoFormat = Self.main10
        var flips: [Bool] = []
        decoder.onHDRActiveChanged = { flips.append($0) }

        decoder.setHDR(enabled: true)
        #expect(layer.preferredDynamicRange == .high)
        #expect(Self.colorSpaceName(of: layer) == CGColorSpace.itur_2100_PQ)
        #expect(decoder.isHDRActive)
        #expect(decoder.hdrMetadataStore.snapshot.mdcv?.count == 24)

        decoder.setHDR(enabled: false)
        #expect(layer.preferredDynamicRange == .standard)
        #expect(layer.value(forKey: "colorspace") == nil)
        #expect(!decoder.isHDRActive)
        #expect(decoder.hdrMetadataStore.snapshot == .empty)
        #expect(flips == [true, false])
    }

    @Test func eightBitStreamStaysSDRWhenThePCSignalsHDR() {
        let decoder = VideoDecoder()
        let layer = AVSampleBufferDisplayLayer()
        decoder.attach(to: layer)
        defer { decoder.teardown() }
        decoder.setBackend(InputRecordingBackend())
        decoder.streamVideoFormat = Self.main8
        var flips: [Bool] = []
        decoder.onHDRActiveChanged = { flips.append($0) }

        decoder.setHDR(enabled: true)
        #expect(decoder.hdrEnabled)
        #expect(layer.preferredDynamicRange == .standard)
        #expect(!decoder.isHDRActive)
        #expect(flips.isEmpty)
    }

    @Test func hdrStateWaitsForALayer() {
        let decoder = VideoDecoder()
        decoder.setBackend(InputRecordingBackend())
        decoder.streamVideoFormat = Self.main10
        decoder.setHDR(enabled: true)
        #expect(decoder.hdrEnabled)
        #expect(!decoder.isHDRActive)
    }

    /// New metadata from the PC mid-stream drops the cached format so the next frame carries it.
    @Test func changedMetadataInvalidatesTheCachedFormat() async throws {
        let decoder = VideoDecoder()
        let backend = InputRecordingBackend()
        backend.hdr = sampleHostHDR
        decoder.setBackend(backend)
        decoder.setHDR(enabled: true)
        decoder.cachedHDRFormatDescription = try Self.formatDescription()

        decoder.setHDR(enabled: true)
        await decoder.decodeQueue.drainForTest()
        #expect(decoder.cachedHDRFormatDescription != nil)

        var brighter = sampleHostHDR
        brighter.maxContentLightLevel = 4_000
        backend.hdr = brighter
        decoder.setHDR(enabled: true)
        await decoder.decodeQueue.drainForTest()
        #expect(decoder.cachedHDRFormatDescription == nil)
        #expect(decoder.hdrMetadataStore.snapshot.contentLightLevel == Data([0x0F, 0xA0, 0x01, 0x90]))
    }

    @Test func fourCCPrintsCodesAndEscapesTheRest() {
        let decoder = VideoDecoder()
        #expect(decoder.fourCCString(from: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange) == "x420")
        #expect(decoder.fourCCString(from: 0x7F41_0042) == "\\x7fA\\x00B")
    }

    static func formatDescription() throws -> CMVideoFormatDescription {
        var format: CMVideoFormatDescription?
        let buffer = try makeTaggedPixelBuffer()
        try #require(CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: nil, imageBuffer: buffer, formatDescriptionOut: &format) == noErr)
        return try #require(format)
    }

    private static func colorSpaceName(of layer: AVSampleBufferDisplayLayer) -> CFString? {
        guard let value = layer.value(forKey: "colorspace") as CFTypeRef?,
              CFGetTypeID(value) == CGColorSpace.typeID else { return nil }
        return unsafeDowncast(value, to: CGColorSpace.self).name
    }
}
