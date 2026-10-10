// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  VideoDecoderEnqueueTests.swift
//
//  A decoded frame's trip to the layer: colour and HDR tags, the format cache, pacer handoff,
//  and what VideoToolbox's output callback does with success and failure.
//

import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import Glimmer

@MainActor
struct VideoDecoderEnqueueTests {

    private let pts = CMTime(value: 90_000, timescale: 90_000)

    /// A streaming decoder with a layer and no pacer, so frames present directly.
    private func liveDecoder(format: Int32, hostHDR: Bool = false) -> VideoDecoder {
        let decoder = VideoDecoder()
        decoder.attach(to: AVSampleBufferDisplayLayer())
        decoder.streamVideoFormat = format
        decoder.hdrEnabled = hostHDR
        decoder.isStreaming = true
        return decoder
    }

    private func attachment(_ buffer: CVPixelBuffer, _ key: CFString) -> String? {
        CVBufferCopyAttachment(buffer, key, nil) as? String
    }

    private func colorSpaceName(_ buffer: CVPixelBuffer) -> CFString? {
        guard let value = CVBufferCopyAttachment(buffer, kCVImageBufferCGColorSpaceKey, nil),
              CFGetTypeID(value) == CGColorSpace.typeID else { return nil }
        return unsafeDowncast(value, to: CGColorSpace.self).name
    }

    /// A PQ frame mis-tagged BT.709 is retagged end to end, so macOS engages display HDR.
    @Test func hdrFrameIsRetaggedAndCarriesThePCsMetadata() throws {
        let decoder = liveDecoder(format: StreamProtocol.VIDEO_FORMAT_H265_MAIN10, hostHDR: true)
        defer { decoder.teardown() }
        let metadata = HDRMetadata(mdcv: Data(repeating: 7, count: 24), contentLightLevel: Data([1, 2, 3, 4]))
        decoder.hdrMetadataStore.publish(metadata)
        let buffer = try makeTaggedPixelBuffer(primaries: kCVImageBufferColorPrimaries_ITU_R_709_2)
        CVBufferSetAttachment(buffer, kCVImageBufferPixelAspectRatioKey,
                              [kCVImageBufferPixelAspectRatioHorizontalSpacingKey: 4] as CFDictionary, .shouldPropagate)

        decoder.enqueueDecodedFrame(buffer, hostPTS: pts)

        #expect(CVBufferCopyAttachment(buffer, kCVImageBufferPixelAspectRatioKey, nil) == nil)
        #expect(colorSpaceName(buffer) == CGColorSpace.itur_2100_PQ)
        #expect(attachment(buffer, kCVImageBufferColorPrimariesKey) == kCVImageBufferColorPrimaries_ITU_R_2020 as String)
        #expect(attachment(buffer, kCVImageBufferTransferFunctionKey)
                == kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String)
        #expect(attachment(buffer, kCVImageBufferYCbCrMatrixKey) == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String)
        #expect(CVBufferCopyAttachment(buffer, kCVImageBufferMasteringDisplayColorVolumeKey, nil) as? Data
                == metadata.mdcv)
        #expect(CVBufferCopyAttachment(buffer, kCVImageBufferContentLightLevelInfoKey, nil) as? Data
                == metadata.contentLightLevel)
        #expect(decoder.lastColorSpaceKey == "itur_2100_PQ")
        #expect(decoder.didLogFirstPixelBufferProbe)
        #expect(decoder.secondsSinceLastPresentedFrame() < 60)
    }

    /// Untagged 10-bit SDR is BT.2020: primaries and matrix follow, the transfer is left alone.
    @Test func untaggedTenBitSDRGetsBT2020WithoutPQ() throws {
        let decoder = liveDecoder(format: StreamProtocol.VIDEO_FORMAT_AV1_MAIN10)
        defer { decoder.teardown() }
        let buffer = try makeTaggedPixelBuffer()

        decoder.enqueueDecodedFrame(buffer, hostPTS: pts)

        #expect(colorSpaceName(buffer) == CGColorSpace.itur_2020)
        #expect(attachment(buffer, kCVImageBufferColorPrimariesKey) == kCVImageBufferColorPrimaries_ITU_R_2020 as String)
        #expect(attachment(buffer, kCVImageBufferYCbCrMatrixKey) == kCVImageBufferYCbCrMatrix_ITU_R_2020 as String)
        #expect(attachment(buffer, kCVImageBufferTransferFunctionKey) == nil)
        #expect(CVBufferCopyAttachment(buffer, kCVImageBufferMasteringDisplayColorVolumeKey, nil) == nil)
    }

    @Test func sdrFrameKeepsItsOwnTags() throws {
        let decoder = liveDecoder(format: StreamProtocol.VIDEO_FORMAT_H264)
        defer { decoder.teardown() }
        let buffer = try makeTaggedPixelBuffer(
            primaries: kCVImageBufferColorPrimaries_ITU_R_709_2,
            transfer: kCVImageBufferTransferFunction_ITU_R_709_2,
            format: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)

        decoder.enqueueDecodedFrame(buffer, hostPTS: pts)

        #expect(colorSpaceName(buffer) == CGColorSpace.itur_709)
        #expect(attachment(buffer, kCVImageBufferColorPrimariesKey) == kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
        #expect(attachment(buffer, kCVImageBufferTransferFunctionKey) == kCVImageBufferTransferFunction_ITU_R_709_2 as String)
        #expect(attachment(buffer, kCVImageBufferYCbCrMatrixKey) == nil)
    }

    /// Same-shaped frames reuse one format description; a resolution change builds a new one.
    @Test func formatDescriptionIsCachedUntilTheFrameChangesShape() throws {
        let decoder = liveDecoder(format: StreamProtocol.VIDEO_FORMAT_H265_MAIN10)
        defer { decoder.teardown() }
        decoder.enqueueDecodedFrame(try makeTaggedPixelBuffer(), hostPTS: pts)
        let first = try #require(decoder.cachedHDRFormatDescription)

        decoder.enqueueDecodedFrame(try makeTaggedPixelBuffer(), hostPTS: pts)
        #expect(decoder.cachedHDRFormatDescription === first)

        decoder.enqueueDecodedFrame(try makeTaggedPixelBuffer(width: 32, height: 16), hostPTS: pts)
        let resized = try #require(decoder.cachedHDRFormatDescription)
        #expect(resized !== first)
        #expect(CMVideoFormatDescriptionGetDimensions(resized).width == 32)
    }

    @Test func framesAfterStopOrWithoutALayerAreDiscarded() throws {
        let stopped = liveDecoder(format: StreamProtocol.VIDEO_FORMAT_H265_MAIN10, hostHDR: true)
        stopped.isStreaming = false
        let layerless = VideoDecoder()
        layerless.isStreaming = true
        for decoder in [stopped, layerless] {
            let buffer = try makeTaggedPixelBuffer()
            decoder.enqueueDecodedFrame(buffer, hostPTS: pts)
            #expect(colorSpaceName(buffer) == nil)
            #expect(decoder.cachedHDRFormatDescription == nil)
            #expect(decoder.secondsSinceLastPresentedFrame() == .infinity)
        }
        stopped.teardown()
    }

    /// With pacing up the frame waits in the pacer for its vsync instead of reaching the renderer.
    @Test func pacedFrameQueuesInThePacer() throws {
        let decoder = liveDecoder(format: StreamProtocol.VIDEO_FORMAT_H265)
        defer { decoder.teardown() }
        let pacer = FramePacer(stats: decoder.statsCollector, configuredFps: 120)
        pacer.running = true
        decoder.framePacer = pacer

        decoder.enqueueDecodedFrame(try makeTaggedPixelBuffer(), hostPTS: pts)

        #expect(pacer.queue.count == 1)
        #expect(pacer.queue.first.map { CMSampleBufferGetPresentationTimeStamp($0.sampleBuffer) } == pts)
        #expect(decoder.secondsSinceLastPresentedFrame() == .infinity)
    }

    // MARK: VT output callback

    private func deliver(_ decoder: VideoDecoder, status: OSStatus, image: CVPixelBuffer?, epoch: UInt = 0) {
        VideoDecoder.decompressionOutputCallback(
            Unmanaged.passUnretained(decoder).toOpaque(), UnsafeMutableRawPointer(bitPattern: epoch),
            status, [], image, pts, .invalid)
    }

    /// A failed frame frees its slot and arms one resync; nothing is presented.
    @Test func failedOutputRetiresTheSlotAndResyncs() {
        let decoder = liveDecoder(format: StreamProtocol.VIDEO_FORMAT_H265)
        defer { decoder.teardown() }
        decoder.inFlightDecodes = 2

        deliver(decoder, status: -12_909, image: nil)

        #expect(decoder.inFlightDecodeBacklog() == 1)
        #expect(decoder.lastVtDecodeFailed)
        #expect(decoder.secondsSinceLastDecodedFrame() == .infinity)
        #expect(!decoder.didFireFirstDecodedFrame)
        #expect(decoder.decodeGateDisposition(isIDR: false) == .resyncToIdr)
    }

    @Test func decodedOutputPresentsAndFiresTheFirstFrameOnce() async throws {
        let decoder = liveDecoder(format: StreamProtocol.VIDEO_FORMAT_H265_MAIN10)
        defer { decoder.teardown() }
        decoder.inFlightDecodes = 1
        decoder.lastVtDecodeFailed = true
        var fired = 0
        decoder.onFirstDecodedFrame = { fired += 1 }

        deliver(decoder, status: noErr, image: try makeTaggedPixelBuffer())

        #expect(decoder.inFlightDecodeBacklog() == 0)
        #expect(!decoder.lastVtDecodeFailed)
        #expect(decoder.secondsSinceLastDecodedFrame() < 60)
        #expect(decoder.secondsSinceLastPresentedFrame() < 60)
        #expect(decoder.didFireFirstDecodedFrame)
        #expect(decoder.decodeGateDisposition(isIDR: false) == .feed(epoch: 0))
        for _ in 0..<200 where fired == 0 {
            try await Task.sleep(for: .milliseconds(10))
        }
        #expect(fired == 1)
    }
}
