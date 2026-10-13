// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  VideoDecoderHDRTests.swift
//
//  Which colorspace a decoded frame is tagged with, the HDR10 metadata blobs, and the layer's HDR mode.
//

import GlimmerEngine
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

    struct ColorCase: Sendable {
        let format: Int32
        let controlHDR: Bool
        let primaries: String?
        let transfer: String?
        let expectedPrimaries: String
        let expectedTransfer: String
    }

    nonisolated static let main10 = StreamProtocol.VIDEO_FORMAT_H265_MAIN10
    nonisolated static let main8 = StreamProtocol.VIDEO_FORMAT_H265
    nonisolated static let bt2020 = kCVImageBufferColorPrimaries_ITU_R_2020 as String
    nonisolated static let bt709 = kCVImageBufferColorPrimaries_ITU_R_709_2 as String
    nonisolated static let pq = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String
    nonisolated static let hlg = kCVImageBufferTransferFunction_ITU_R_2100_HLG as String
    nonisolated static let sdr = kCVImageBufferTransferFunction_ITU_R_709_2 as String
    nonisolated static let p3 = kCVImageBufferColorPrimaries_P3_D65 as String

    nonisolated static let colorCases: [ColorCase] = [
        ColorCase(format: main8, controlHDR: false, primaries: bt709, transfer: sdr,
                  expectedPrimaries: bt709, expectedTransfer: sdr),
        ColorCase(format: main10, controlHDR: true, primaries: bt709, transfer: sdr,
                  expectedPrimaries: bt709, expectedTransfer: sdr),
        ColorCase(format: main10, controlHDR: true, primaries: bt2020, transfer: sdr,
                  expectedPrimaries: bt2020, expectedTransfer: sdr),
        ColorCase(format: main10, controlHDR: false, primaries: nil, transfer: nil,
                  expectedPrimaries: bt709, expectedTransfer: sdr),
        ColorCase(format: main10, controlHDR: true, primaries: nil, transfer: nil,
                  expectedPrimaries: bt2020, expectedTransfer: pq),
        ColorCase(format: main8, controlHDR: true, primaries: nil, transfer: nil,
                  expectedPrimaries: bt709, expectedTransfer: sdr),
        ColorCase(format: main10, controlHDR: false, primaries: bt2020, transfer: pq,
                  expectedPrimaries: bt2020, expectedTransfer: pq),
        ColorCase(format: main10, controlHDR: true, primaries: bt2020, transfer: hlg,
                  expectedPrimaries: bt2020, expectedTransfer: hlg),
        ColorCase(format: main10, controlHDR: false, primaries: bt2020, transfer: hlg,
                  expectedPrimaries: bt2020, expectedTransfer: hlg),
        ColorCase(format: main10, controlHDR: true, primaries: bt709, transfer: nil,
                  expectedPrimaries: bt709, expectedTransfer: sdr),
        ColorCase(format: main10, controlHDR: true, primaries: nil, transfer: sdr,
                  expectedPrimaries: bt709, expectedTransfer: sdr),
        ColorCase(format: main10, controlHDR: false, primaries: nil, transfer: pq,
                  expectedPrimaries: bt2020, expectedTransfer: pq),
        ColorCase(format: main10, controlHDR: true, primaries: nil, transfer: hlg,
                  expectedPrimaries: bt2020, expectedTransfer: hlg),
        ColorCase(format: main10, controlHDR: true, primaries: bt2020, transfer: nil,
                  expectedPrimaries: bt2020, expectedTransfer: pq),
        ColorCase(format: main10, controlHDR: false, primaries: bt2020, transfer: nil,
                  expectedPrimaries: bt2020, expectedTransfer: sdr),
        ColorCase(format: main8, controlHDR: true, primaries: bt2020, transfer: nil,
                  expectedPrimaries: bt2020, expectedTransfer: sdr),
        ColorCase(format: main10, controlHDR: false, primaries: p3, transfer: sdr,
                  expectedPrimaries: p3, expectedTransfer: sdr)
    ]

    @Test(arguments: colorCases)
    func resolvedColorPreservesDeclarations(_ testCase: ColorCase) throws {
        let decoder = VideoDecoder()
        decoder.streamVideoFormat = testCase.format
        let buffer = try makeTaggedPixelBuffer(
            primaries: testCase.primaries.map { $0 as CFString }, transfer: testCase.transfer.map { $0 as CFString })
        let color = decoder.resolveColorDescription(for: buffer, controlHDR: testCase.controlHDR)
        #expect(color.primaries == testCase.expectedPrimaries)
        #expect(color.transfer == testCase.expectedTransfer)
        #expect(color.isHDR == [Self.pq, Self.hlg].contains(testCase.expectedTransfer))
        #expect(color.range == kCVPixelFormatComponentRange_VideoRange as String)
        #expect(color.makeColorSpace() != nil)
        if testCase.expectedPrimaries == Self.bt2020 {
            #expect(color.matrix == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String)
        }
        if color.isHDR {
            let name = color.makeColorSpace()?.name as String?
            #expect(name == (color.transfer == Self.pq
                ? CGColorSpace.itur_2100_PQ as String : CGColorSpace.itur_2100_HLG as String))
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

    @Test func tenBitHDRStreamEngagesTheLayerAndBackOff() throws {
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
        #expect(!decoder.isHDRActive)
        let hdr = try makeTaggedPixelBuffer()
        decoder.attachColorAndHDRMetadata(to: hdr,
            color: decoder.resolveColorDescription(for: hdr, controlHDR: true))
        decoder.configureLayerColorspace()
        #expect(layer.preferredDynamicRange == .high)
        #expect(decoder.isHDRActive)
        #expect(decoder.hdrMetadataStore.snapshot.mdcv?.count == 24)

        decoder.setHDR(enabled: false)
        let sdr = try makeTaggedPixelBuffer()
        decoder.attachColorAndHDRMetadata(to: sdr,
            color: decoder.resolveColorDescription(for: sdr, controlHDR: false))
        decoder.configureLayerColorspace()
        #expect(layer.preferredDynamicRange == .standard)
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
}

@MainActor
struct VideoDecoderColorTransitionTests {
    private let bt2020 = kCVImageBufferColorPrimaries_ITU_R_2020
    private let pq = kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ
    private let hlg = kCVImageBufferTransferFunction_ITU_R_2100_HLG
    private let sdr = kCVImageBufferTransferFunction_ITU_R_709_2

    @Test func aMatrixAlonePreservesTheUntaggedPQFallback() throws {
        let decoder = VideoDecoder()
        decoder.streamVideoFormat = StreamProtocol.VIDEO_FORMAT_H265_MAIN10
        let buffer = try makeTaggedPixelBuffer()
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        let color = decoder.resolveColorDescription(for: buffer, controlHDR: true)
        #expect(color.primaries == bt2020 as String)
        #expect(color.transfer == pq as String)
        #expect(color.matrix == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String)
        #expect(color.isHDR)
    }

    @Test func independentTagsAndGammaSurviveAttachment() throws {
        let decoder = VideoDecoder()
        decoder.streamVideoFormat = StreamProtocol.VIDEO_FORMAT_H265_MAIN10
        let buffer = try makeTaggedPixelBuffer(primaries: kCVImageBufferColorPrimaries_P3_D65,
                                               transfer: kCVImageBufferTransferFunction_UseGamma)
        CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_601_4, .shouldPropagate)
        CVBufferSetAttachment(buffer, kCVImageBufferGammaLevelKey, 2.2 as CFNumber, .shouldPropagate)
        let declaredGamma = try #require(CVBufferCopyAttachment(buffer, kCVImageBufferGammaLevelKey, nil) as? Double)
        let color = decoder.resolveColorDescription(for: buffer, controlHDR: true)
        decoder.attachColorAndHDRMetadata(to: buffer, color: color)
        #expect(color.primaries == kCVImageBufferColorPrimaries_P3_D65 as String)
        #expect(color.transfer == kCVImageBufferTransferFunction_UseGamma as String)
        #expect(color.matrix == kCVImageBufferYCbCrMatrix_ITU_R_601_4 as String)
        #expect(abs(declaredGamma - 2.2) < 0.000001)
        #expect(color.gamma == declaredGamma)
        #expect(!color.isHDR)
        #expect(CVBufferCopyAttachment(buffer, kCVImageBufferGammaLevelKey, nil) as? Double == declaredGamma)
    }

    @Test(arguments: [kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
                      kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange])
    func outputRangeIsNotReplacedWithTheRequestedRange(_ format: OSType) throws {
        let decoder = VideoDecoder(colorRange: .full)
        let buffer = try makeTaggedPixelBuffer(format: format)
        let color = decoder.resolveColorDescription(for: buffer, controlHDR: false)
        decoder.attachColorAndHDRMetadata(to: buffer, color: color)
        let full = format == kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        #expect(color.range == (full ? kCVPixelFormatComponentRange_FullRange as String
            : kCVPixelFormatComponentRange_VideoRange as String))
        #expect(CVPixelBufferGetPixelFormatType(buffer) == format)
    }

    @Test func inputFormatTagsFillMissingVTAttachments() throws {
        let decoder = VideoDecoder()
        let tagged = try makeTaggedPixelBuffer(primaries: bt2020, transfer: hlg)
        CVBufferSetAttachment(tagged, kCVImageBufferYCbCrMatrixKey,
                              kCVImageBufferYCbCrMatrix_ITU_R_2020, .shouldPropagate)
        var format: CMVideoFormatDescription?
        try #require(CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: nil, imageBuffer: tagged, formatDescriptionOut: &format) == noErr)
        decoder.formatDescription = format
        let untagged = try makeTaggedPixelBuffer()
        let color = decoder.resolveColorDescription(for: untagged, controlHDR: false)
        #expect(color.primaries == bt2020 as String)
        #expect(color.transfer == hlg as String)
        #expect(color.matrix == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String)
        #expect(color.isHDR)
        let probe = try #require(decoder.beginColorProbe(untagged, color: color, controlHDR: false))
        #expect(probe.rawFormat.contains("ITU_R_2020"))
        #expect(probe.rawFormat.contains("ITU_R_2100_HLG"))
        #expect(!probe.rawAttachments.contains("ITU_R_2100_HLG"))
    }

    @Test func hdrToSDRRemovesMetadataAndInvalidatesTheFormat() throws {
        let decoder = VideoDecoder()
        decoder.attach(to: AVSampleBufferDisplayLayer())
        decoder.isStreaming = true
        decoder.streamVideoFormat = StreamProtocol.VIDEO_FORMAT_H265_MAIN10
        decoder.hdrEnabled = true
        defer { decoder.teardown() }
        let metadata = HDRMetadata(mdcv: Data(repeating: 1, count: 24), contentLightLevel: Data([0, 1, 0, 1]))
        decoder.hdrMetadataStore.publish(metadata)
        let buffer = try makeTaggedPixelBuffer(primaries: bt2020, transfer: pq)
        decoder.enqueueDecodedFrame(buffer, hostPTS: .zero)
        let hdrFormat = try #require(decoder.cachedHDRFormatDescription)
        #expect(CVBufferCopyAttachment(buffer, kCVImageBufferMasteringDisplayColorVolumeKey, nil) != nil)

        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, sdr, .shouldPropagate)
        decoder.enqueueDecodedFrame(buffer, hostPTS: .zero)
        let sdrFormat = try #require(decoder.cachedHDRFormatDescription)
        #expect(sdrFormat !== hdrFormat)
        #expect(CVBufferCopyAttachment(buffer, kCVImageBufferMasteringDisplayColorVolumeKey, nil) == nil)
        #expect(CVBufferCopyAttachment(buffer, kCVImageBufferContentLightLevelInfoKey, nil) == nil)
        #expect(CMFormatDescriptionGetExtension(sdrFormat,
            extensionKey: kCMFormatDescriptionExtension_MasteringDisplayColorVolume) == nil)
        #expect(CMFormatDescriptionGetExtension(sdrFormat,
            extensionKey: kCMFormatDescriptionExtension_ContentLightLevelInfo) == nil)
        #expect(decoder.resolvedColor.withLock { $0?.primaries } == bt2020 as String)
        #expect(decoder.resolvedColor.withLock { $0?.isHDR } == false)

        CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, hlg, .shouldPropagate)
        decoder.enqueueDecodedFrame(buffer, hostPTS: .zero)
        #expect(decoder.cachedHDRFormatDescription !== sdrFormat)
        #expect(CVBufferCopyAttachment(buffer, kCVImageBufferContentLightLevelInfoKey, nil) as? Data
            == metadata.contentLightLevel)
    }

    @Test func taggedHDRControlsReplacementLayersWithoutAControlSignal() throws {
        let decoder = VideoDecoder()
        defer { decoder.teardown() }
        for transfer in [pq, hlg, sdr] {
            let buffer = try makeTaggedPixelBuffer(primaries: bt2020, transfer: transfer)
            let color = decoder.resolveColorDescription(for: buffer, controlHDR: false)
            decoder.attachColorAndHDRMetadata(to: buffer, color: color)
            let layer = AVSampleBufferDisplayLayer()
            decoder.attach(to: layer)
            decoder.configureLayerColorspace()
            #expect(layer.preferredDynamicRange == (color.isHDR ? .high : .standard))
            #expect(decoder.isHDRActive == color.isHDR)
        }
    }

    @Test func probeCapturesRawStateAndOnlyRepeatsForChanges() throws {
        let decoder = VideoDecoder()
        decoder.streamVideoFormat = StreamProtocol.VIDEO_FORMAT_H265_MAIN10
        let buffer = try makeTaggedPixelBuffer()
        let color = decoder.resolveColorDescription(for: buffer, controlHDR: false)
        let first = try #require(decoder.beginColorProbe(buffer, color: color, controlHDR: false))
        #expect(!first.rawAttachments.contains("ITU_R_709_2"))
        decoder.attachColorAndHDRMetadata(to: buffer, color: color)
        #expect(decoder.colorAttachmentSummary(buffer).contains("ITU_R_709_2"))
        let next = try makeTaggedPixelBuffer()
        #expect(decoder.beginColorProbe(next, color: color, controlHDR: false) == nil)
        #expect(decoder.beginColorProbe(next, color: color, controlHDR: true) != nil)
        #expect(decoder.beginColorProbe(next, color: color, controlHDR: true) == nil)
        let tagged = try makeTaggedPixelBuffer(primaries: bt2020, transfer: hlg)
        let changed = decoder.resolveColorDescription(for: tagged, controlHDR: true)
        #expect(decoder.beginColorProbe(tagged, color: changed, controlHDR: true) != nil)
        #expect(decoder.beginColorProbe(tagged, color: changed, controlHDR: true) == nil)
    }

    @Test func stableColorReusesItsAttachmentDictionary() throws {
        let decoder = VideoDecoder()
        let firstBuffer = try makeTaggedPixelBuffer()
        let first = decoder.resolveColorDescription(for: firstBuffer, controlHDR: false)
        decoder.attachColorAndHDRMetadata(to: firstBuffer, color: first)
        let second = decoder.resolveColorDescription(for: try makeTaggedPixelBuffer(), controlHDR: false)
        let firstAttachments = first.attachments as CFDictionary
        let secondAttachments = second.attachments as CFDictionary
        #expect(firstAttachments === secondAttachments)
    }

    @Test func rangeCacheKeepsEachPixelFormatSeparate() throws {
        let decoder = VideoDecoder()
        let full = kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        let video = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange
        for format in [full, video, full, video] {
            let color = decoder.resolveColorDescription(
                for: try makeTaggedPixelBuffer(format: format), controlHDR: false)
            #expect(color.range == (format == full ? kCVPixelFormatComponentRange_FullRange as String
                : kCVPixelFormatComponentRange_VideoRange as String))
        }
        #expect(decoder.pixelFormatRanges.withLock { $0.count } == 2)
    }

    @Test(arguments: [false, true])
    func displayReprobesStopAtSDROrTeardown(teardown: Bool) async throws {
        let decoder = VideoDecoder()
        let delay = TestDelay()
        decoder.colorProbeSleep = delay.sleep
        decoder.colorProbeLog = { _, _ in }
        var requests = delay.requests.stream.makeAsyncIterator()
        decoder.attach(to: AVSampleBufferDisplayLayer())
        defer { decoder.teardown() }
        let buffer = try makeTaggedPixelBuffer(primaries: bt2020, transfer: pq)
        let color = decoder.resolveColorDescription(for: buffer, controlHDR: false)
        decoder.resolvedColor.withLock { $0 = color }
        var probes = 0
        decoder.configureLayerColorspace(headroom: { probes += 1; return (1, 4) })
        let task = try #require(decoder.colorDisplayProbeTask)
        #expect(await requests.next() == .seconds(1))
        if teardown {
            decoder.teardown()
        } else {
            decoder.resolvedColor.withLock { $0 = nil }
            decoder.configureLayerColorspace()
        }
        delay.resume()
        await task.value
        #expect(task.isCancelled)
        #expect(probes == 1)
    }

    @Test func probeAppliesDynamicRangeBeforeLogging() async throws {
        let decoder = VideoDecoder()
        decoder.colorProbeSleep = { _ in throw CancellationError() }
        var rows: [String] = []
        decoder.colorProbeLog = { message, _ in rows.append(message.text) }
        let layer = AVSampleBufferDisplayLayer()
        decoder.attach(to: layer)
        layer.preferredDynamicRange = .standard
        defer { decoder.teardown() }
        let buffer = try makeTaggedPixelBuffer(primaries: bt2020, transfer: pq)
        let color = decoder.resolveColorDescription(for: buffer, controlHDR: false)
        decoder.resolvedColor.withLock { $0 = color }
        let probe = try #require(decoder.beginColorProbe(buffer, color: color, controlHDR: false))
        let task = try #require(decoder.finishColorProbe(probe, pixelBuffer: buffer))
        await task.value
        let row = try #require(rows.last { $0.hasPrefix("Colour probe display:") })
        #expect(row.contains("preferredDynamicRange=high"))
        #expect(layer.preferredDynamicRange == .high)
    }

    @Test func hdrTransitionReprobesDisplayHeadroom() async throws {
        let decoder = VideoDecoder()
        let delay = TestDelay()
        decoder.colorProbeSleep = delay.sleep
        var rows: [String] = []
        var warnings: [String] = []
        decoder.colorProbeLog = { message, warning in
            if warning { warnings.append(message.text) } else { rows.append(message.text) }
        }
        var requests = delay.requests.stream.makeAsyncIterator()
        decoder.attach(to: AVSampleBufferDisplayLayer())
        defer { decoder.teardown() }
        let buffer = try makeTaggedPixelBuffer(primaries: bt2020, transfer: pq)
        let color = decoder.resolveColorDescription(for: buffer, controlHDR: false)
        decoder.resolvedColor.withLock { $0 = color }
        decoder.configureLayerColorspace(headroom: { (1, 4) })
        let task = try #require(decoder.colorDisplayProbeTask)
        for (index, seconds) in [1, 2, 2].enumerated() {
            #expect(await requests.next() == .seconds(seconds))
            #expect(rows.count == index + 1)
            #expect(warnings.isEmpty)
            delay.resume()
        }
        await task.value
        #expect(warnings == ["HDR input has no EDR headroom: currentEDR=1.0 potentialEDR=4.0"])
        #expect(rows == [0, 1, 3, 5].map {
            "Colour display transition: after=\($0)s currentEDR=1.0 potentialEDR=4.0 "
                + "hdrInput=true hdrOutput=false preferredDynamicRange=high"
        })
    }

    @Test func inputHDRSurvivesMovementWhileOutputTracksCurrentEDR() {
        let outputs = [1.0, 2.0, 1.0, 4.0].map {
            VideoColorDescription.hdrDisplayOutput(inputHDR: true, currentEDR: $0)
        }
        #expect(outputs == [false, true, false, true])
        #expect(!VideoColorDescription.hdrDisplayOutput(inputHDR: false, currentEDR: 4))
    }
}
