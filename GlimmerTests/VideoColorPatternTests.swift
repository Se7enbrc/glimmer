// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AVFoundation
import CoreVideo
import Foundation
import Synchronization
import Testing
import VideoToolbox
@testable import GlimmerEngine

@MainActor
struct VideoColorPatternTests {
    @Test(arguments: [VideoFormats.hevcMain10.rawValue, VideoFormats.av1Main10.rawValue])
    func referenceRampRetainsTenBitSamplesAndTagsAcrossTransitions(format: Int32) throws {
        let decoder = VideoDecoder()
        decoder.streamVideoFormat = format
        let layer = AVSampleBufferDisplayLayer()
        decoder.attach(to: layer)
        defer { decoder.teardown() }
        let transfers = [kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
                         kCVImageBufferTransferFunction_ITU_R_2100_HLG,
                         kCVImageBufferTransferFunction_ITU_R_709_2]
        let buffer = try referenceRamp()
        for transfer in transfers {
            let hdr = transfer != kCVImageBufferTransferFunction_ITU_R_709_2
            let primaries = hdr ? kCVImageBufferColorPrimaries_ITU_R_2020 : kCVImageBufferColorPrimaries_ITU_R_709_2
            CVBufferSetAttachment(buffer, kCVImageBufferColorPrimariesKey, primaries, .shouldPropagate)
            CVBufferSetAttachment(buffer, kCVImageBufferTransferFunctionKey, transfer, .shouldPropagate)
            let matrix = hdr ? kCVImageBufferYCbCrMatrix_ITU_R_2020 : kCVImageBufferYCbCrMatrix_ITU_R_709_2
            CVBufferSetAttachment(buffer, kCVImageBufferYCbCrMatrixKey, matrix, .shouldPropagate)
            decoder.hdrMetadataStore.publish(HDRMetadata(mdcv: nil,
                                                        contentLightLevel: Data([3, 232, 1, 144])))
            let color = decoder.resolveColorDescription(for: buffer, controlHDR: true)
            decoder.attachColorAndHDRMetadata(to: buffer, color: color)
            decoder.configureLayerColorspace()
            #expect(color.isHDR == hdr)
            #expect(color.primaries == primaries as String)
            #expect(color.transfer == transfer as String)
            #expect(color.matrix == matrix as String)
            #expect(color.range == kCVPixelFormatComponentRange_VideoRange as String)
            #expect(color.makeColorSpace() != nil)
            #expect(decoder.isHDRActive == hdr)
            #expect(layer.dynamicRangeLabel == (hdr ? highRangeLabel : "standard"))
            #expect((CVBufferCopyAttachment(buffer, kCVImageBufferContentLightLevelInfoKey, nil) != nil) == hdr)
            var description: CMVideoFormatDescription?
            try #require(CMVideoFormatDescriptionCreateForImageBuffer(
                allocator: nil, imageBuffer: buffer, formatDescriptionOut: &description) == noErr)
            let resolved = try #require(description)
            #expect(CMFormatDescriptionGetExtension(resolved,
                extensionKey: kCMFormatDescriptionExtension_TransferFunction) as? String == transfer as String)
            #expect(try lumaSamples(buffer) == Self.ramp.map { $0 << 6 })
        }
    }

    @Test func compressedHLGTagsFillMissingPixelTagsAndExplicitSDRWins() throws {
        let decoder = VideoDecoder()
        let source = try referenceRamp()
        CVBufferSetAttachment(source, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_2100_HLG, .shouldPropagate)
        var description: CMVideoFormatDescription?
        try #require(CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: nil, imageBuffer: source, formatDescriptionOut: &description) == noErr)
        let sourceFormat = try #require(description)
        decoder.formatDescription = sourceFormat
        let output = try referenceRamp()
        let hlg = decoder.resolveColorDescription(for: output, controlHDR: false)
        #expect(hlg.isHDR)
        #expect(hlg.primaries == kCVImageBufferColorPrimaries_ITU_R_2020 as String)
        #expect(hlg.matrix == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String)
        CVBufferSetAttachment(output, kCVImageBufferTransferFunctionKey,
                              kCVImageBufferTransferFunction_ITU_R_709_2, .shouldPropagate)
        #expect(decoder.resolveColorDescription(for: output, controlHDR: true).isHDR == false)
    }

    @Test(arguments: [VideoFormats.hevcMain10.rawValue, VideoFormats.av1Main10.rawValue])
    func tenBitDecodeRequiresHardwareAndAnIOSurface(format: Int32) throws {
        let calls = Mutex(0)
        let decoder = VideoDecoder(makeSession: { _, specification, attributes, _ in
            calls.withLock { $0 += 1 }
            #expect(specification[kVTVideoDecoderSpecification_RequireHardwareAcceleratedVideoDecoder as String]
                as? Bool == true)
            #expect(attributes[kCVPixelBufferPixelFormatTypeKey as String] as? OSType
                == kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange)
            #expect(attributes[kCVPixelBufferIOSurfacePropertiesKey as String] != nil)
            return (kVTVideoDecoderNotAvailableNowErr, nil)
        })
        decoder.streamVideoFormat = format
        let buffer = try referenceRamp()
        var description: CMVideoFormatDescription?
        try #require(CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: nil, imageBuffer: buffer, formatDescriptionOut: &description) == noErr)
        let sourceFormat = try #require(description)
        decoder.formatDescription = sourceFormat
        #expect(decoder.ensureDecompressionSession() == false)
        #expect(calls.withLock { $0 } == 1)
        #expect(decoder.decompressionSession == nil)
    }

    @Test func panelHeadroomDoesNotChangeDeclaredInput() {
        #expect(VideoColorDescription.hdrDisplayOutput(inputHDR: true, currentEDR: 1) == false)
        #expect(VideoColorDescription.hdrDisplayOutput(inputHDR: true, currentEDR: 2))
        #expect(VideoColorDescription.hdrDisplayOutput(inputHDR: false, currentEDR: 2) == false)
    }

    private var highRangeLabel: String {
        #if os(macOS)
        if #unavailable(macOS 26) { return "edr" }
        #endif
        return "high"
    }

    // Video-range black, near-black, intermediate steps, near-white and white in 10-bit storage.
    private static let ramp: [UInt16] = [64, 65, 66, 128, 256, 512, 939, 940]

    private func referenceRamp() throws -> CVPixelBuffer {
        var image: CVPixelBuffer?
        try #require(CVPixelBufferCreate(nil, 16, 16, kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange,
            [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary, &image) == kCVReturnSuccess)
        let buffer = try #require(image)
        try #require(CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let luma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0))
        let chroma = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 1))
        for row in 0..<16 {
            let pixels = luma.advanced(by: row * CVPixelBufferGetBytesPerRowOfPlane(buffer, 0))
                .assumingMemoryBound(to: UInt16.self)
            for column in 0..<16 { pixels[column] = Self.ramp[column / 2] << 6 }
        }
        for row in 0..<8 {
            let pixels = chroma.advanced(by: row * CVPixelBufferGetBytesPerRowOfPlane(buffer, 1))
                .assumingMemoryBound(to: UInt16.self)
            for column in 0..<16 { pixels[column] = 512 << 6 }
        }
        return buffer
    }

    private func lumaSamples(_ buffer: CVPixelBuffer) throws -> [UInt16] {
        try #require(CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let base = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt16.self)
        return stride(from: 0, to: 16, by: 2).map { base[$0] }
    }
}
