// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  VideoDecoderEnqueueTests.swift
//
//  A decoded frame's trip to the layer: colour and HDR tags, the format cache, pacer handoff,
//  and what VideoToolbox's output callback does with success and failure.
//

@testable import GlimmerEngine
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import Testing
import VideoToolbox
import os
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

    enum RendererBoundary: CaseIterable {
        case stop, restart, hide, hideAndReturn, replacement, flush
    }

    @Test(arguments: RendererBoundary.allCases)
    func aPreparedRendererSubmissionCannotCrossALifecycleBoundary(_ boundary: RendererBoundary) throws {
        let decoder = liveDecoder(format: StreamProtocol.VIDEO_FORMAT_H265)
        defer { decoder.teardown() }
        let prepared = try #require(decoder.rendererSubmission())
        switch boundary {
        case .stop: decoder.isStreaming = false
        case .restart:
            decoder.isStreaming = false
            decoder.isStreaming = true
        case .hide: decoder.setPresentSuppressed(true)
        case .hideAndReturn:
            decoder.setPresentSuppressed(true)
            decoder.setPresentSuppressed(false)
        case .replacement: decoder.attach(to: AVSampleBufferDisplayLayer())
        case .flush: decoder.flushRenderer(prepared.renderer)
        }
        var enqueued = false
        #expect(!decoder.performRendererSubmission(prepared, enqueue: { _ in enqueued = true }))
        #expect(!enqueued)
        if decoder.isStreaming && !decoder.presentSuppressed {
            let fresh = try #require(decoder.rendererSubmission())
            #expect(decoder.performRendererSubmission(fresh, enqueue: { _ in enqueued = true }))
            #expect(enqueued)
        }
    }

    @Test(arguments: [false, true])
    func aRoutedFrameCannotAcquireANewRendererTokenAfterAModeSwitch(toDirect: Bool) throws {
        let decoder = liveDecoder(format: StreamProtocol.VIDEO_FORMAT_H265)
        defer { decoder.teardown() }
        let pacer = FramePacer(stats: decoder.statsCollector, configuredFps: 120)
        pacer.armWarmHandover()
        if toDirect { decoder.framePacer = pacer }
        let oldRoute = decoder.presentationRoute()
        let prepared = try #require(decoder.rendererSubmission(modeGeneration: oldRoute.generation))
        decoder.framePacer = toDirect ? nil : pacer
        let freshRoute = decoder.presentationRoute()
        let fresh = try #require(decoder.rendererSubmission(modeGeneration: freshRoute.generation))
        var accepted = 0
        #expect(decoder.performRendererSubmission(fresh, enqueue: { _ in accepted += 1 }))
        #expect(decoder.rendererSubmission(modeGeneration: oldRoute.generation) == nil)
        #expect(!decoder.performRendererSubmission(prepared, enqueue: { _ in accepted += 1 }))
        #expect(accepted == 1)
    }

    @Test func anExtractedPacedFrameRetainsItsOriginalModeGeneration() throws {
        let decoder = liveDecoder(format: StreamProtocol.VIDEO_FORMAT_H265)
        defer { decoder.teardown() }
        let pacer = FramePacer(stats: decoder.statsCollector, configuredFps: 120)
        decoder.framePacer = pacer
        let extractedPresentation = try #require(pacer.willPresent)
        decoder.framePacer = nil
        let direct = try #require(decoder.rendererSubmission())
        #expect(decoder.performRendererSubmission(direct, enqueue: { _ in }))
        #expect(!extractedPresentation(try VideoDecoderLifecycleTests.readySample()))
    }

    @Test func hiddenDirectPresentationDoesNotReachTheRenderer() throws {
        let decoder = liveDecoder(format: StreamProtocol.VIDEO_FORMAT_H265)
        defer { decoder.teardown() }
        decoder.setPresentSuppressed(true)

        #expect(!decoder.presentFrame(try VideoDecoderLifecycleTests.readySample()))
        #expect(decoder.secondsSinceLastPresentedFrame() == .infinity)
    }

    @Test func concurrentOutputsClaimTheFirstFrameOnlyOnce() async throws {
        let decoder = VideoDecoder()
        let claims = OSAllocatedUnfairLock(initialState: 0)
        let finished = DispatchSemaphore(value: 0)
        Thread {
            DispatchQueue.concurrentPerform(iterations: 64) { _ in
                if decoder.claimFirstDecodedFrame() { claims.withLock { $0 += 1 } }
            }
            finished.signal()
        }.start()
        try #require(await finished.waitAsync(for: .seconds(5)) == .success)
        #expect(claims.withLock { $0 } == 1)
        #expect(decoder.didFireFirstDecodedFrame)
        decoder.teardown()
        #expect(decoder.claimFirstDecodedFrame())
        #expect(!decoder.claimFirstDecodedFrame())
    }

    @Test func aConcurrentColorChangeCannotReplaceAPreparedFramesColorSpace() async throws {
        let decoder = VideoDecoder()
        let sdr = VideoColorDescription(primaries: kCVImageBufferColorPrimaries_ITU_R_709_2 as String,
                                        transfer: kCVImageBufferTransferFunction_ITU_R_709_2 as String,
                                        matrix: kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String, range: "video", gamma: nil)
        let hdr = VideoColorDescription(primaries: kCVImageBufferColorPrimaries_ITU_R_2020 as String,
                                        transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String,
                                        matrix: kCVImageBufferYCbCrMatrix_ITU_R_2020 as String, range: "video", gamma: nil)
        let prepared = DispatchSemaphore(value: 0)
        let changed = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        Thread {
            let snapshot = decoder.colorAttachmentSnapshot(for: sdr)
            prepared.signal()
            guard changed.wait(timeout: .now() + 5) == .success else {
                Issue.record("Concurrent colour change did not finish")
                finished.signal()
                return
            }
            do {
                let buffer = try makeTaggedPixelBuffer()
                decoder.attachColorAttachments(snapshot, to: buffer)
                let attached = try #require(CVBufferCopyAttachment(buffer, kCVImageBufferCGColorSpaceKey, nil))
                let expected = try #require(sdr.makeColorSpace())
                let replacement = try #require(hdr.makeColorSpace())
                #expect(CFEqual(attached, expected))
                #expect(!CFEqual(attached, replacement))
            } catch { Issue.record(error) }
            finished.signal()
        }.start()
        defer { changed.signal() }
        try #require(await prepared.waitAsync(for: .seconds(5)) == .success)
        let replacement = decoder.colorAttachmentSnapshot(for: hdr)
        try #require(replacement.colorSpace != nil)
        changed.signal()
        try #require(await finished.waitAsync(for: .seconds(5)) == .success)
        #expect(decoder.colorAttachmentCache.withLock { $0?.color } == hdr)
        decoder.teardown()
    }

    private func attachment(_ buffer: CVPixelBuffer, _ key: CFString) -> String? {
        CVBufferCopyAttachment(buffer, key, nil) as? String
    }

    private func colorSpaceName(_ buffer: CVPixelBuffer) -> CFString? {
        guard let value = CVBufferCopyAttachment(buffer, kCVImageBufferCGColorSpaceKey, nil),
              CFGetTypeID(value) == CGColorSpace.typeID else { return nil }
        return unsafeDowncast(value, to: CGColorSpace.self).name
    }

    /// Untagged Main10 can use the control signal when no colour attribute contradicts it.
    @Test func untaggedHDRCarriesThePCsMetadata() throws {
        let decoder = liveDecoder(format: StreamProtocol.VIDEO_FORMAT_H265_MAIN10, hostHDR: true)
        defer { decoder.teardown() }
        let metadata = HDRMetadata(mdcv: Data(repeating: 7, count: 24), contentLightLevel: Data([1, 2, 3, 4]))
        decoder.hdrMetadataStore.publish(metadata)
        let buffer = try makeTaggedPixelBuffer()
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
        #expect(decoder.resolvedColor.withLock { $0?.isHDR } == true)
        #expect(decoder.colorProbeState.withLock { $0 != nil })
        #expect(decoder.secondsSinceLastPresentedFrame() < 60)
    }

    /// Ten bits alone do not imply either BT.2020 primaries or HDR.
    @Test func untaggedTenBitSDRGetsRec709WithoutPQ() throws {
        let decoder = liveDecoder(format: StreamProtocol.VIDEO_FORMAT_AV1_MAIN10)
        defer { decoder.teardown() }
        let buffer = try makeTaggedPixelBuffer()

        decoder.enqueueDecodedFrame(buffer, hostPTS: pts)

        #expect(colorSpaceName(buffer) == CGColorSpace.coreMedia709)
        #expect(attachment(buffer, kCVImageBufferColorPrimariesKey)
                == kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
        #expect(attachment(buffer, kCVImageBufferYCbCrMatrixKey) == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
        #expect(attachment(buffer, kCVImageBufferTransferFunctionKey)
                == kCVImageBufferTransferFunction_ITU_R_709_2 as String)
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

        #expect(colorSpaceName(buffer) == CGColorSpace.coreMedia709)
        #expect(attachment(buffer, kCVImageBufferColorPrimariesKey)
                == kCVImageBufferColorPrimaries_ITU_R_709_2 as String)
        #expect(attachment(buffer, kCVImageBufferTransferFunctionKey) == kCVImageBufferTransferFunction_ITU_R_709_2 as String)
        #expect(attachment(buffer, kCVImageBufferYCbCrMatrixKey) == kCVImageBufferYCbCrMatrix_ITU_R_709_2 as String)
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

    private func deliver(_ decoder: VideoDecoder, status: OSStatus, image: CVPixelBuffer?, epoch: UInt = 0,
                         flags: VTDecodeInfoFlags = []) {
        VideoDecoder.decompressionOutputCallback(
            Unmanaged.passUnretained(decoder).toOpaque(), UnsafeMutableRawPointer(bitPattern: epoch),
            status, flags, image, pts, .invalid)
    }

    /// A failed frame frees its slot and arms one resync; nothing is presented.
    @Test func failedOutputRetiresTheSlotAndResyncs() {
        let decoder = liveDecoder(format: StreamProtocol.VIDEO_FORMAT_H265)
        defer { decoder.teardown() }
        decoder.inFlightDecodes = 2
        decoder.decodeReservations[0] = VideoDecoder.DecodeReservations(submitted: 2)

        deliver(decoder, status: -12_909, image: nil)

        #expect(decoder.inFlightDecodeBacklog() == 1)
        #expect(decoder.lastVtDecodeFailed)
        #expect(decoder.secondsSinceLastDecodedFrame() == .infinity)
        #expect(!decoder.didFireFirstDecodedFrame)
        #expect(decoder.decodeGateDisposition(isIDR: false) == .resyncToIdr)
    }

    @Test func retiredCallbackCannotPublishDecodedProgressOrConsumeARecoverySlot() throws {
        let decoder = liveDecoder(format: StreamProtocol.VIDEO_FORMAT_H265)
        defer { decoder.teardown() }
        _ = decoder.reserveDecodeSlot(isIDR: false, epoch: 1)
        #expect(decoder.beginSubmittedDecode(epoch: 1))
        decoder.lastVtDecodeFailed = true
        decoder.statsCollector.lastDecodedFrameTime = CACurrentMediaTime() - 5
        #expect(decoder.reserveDecodeSlot(isIDR: true, epoch: 2) == .reservedForStallRecreate)
        let decodedBefore = decoder.statsCollector.lastDecodedFrameTime

        deliver(decoder, status: noErr, image: try makeTaggedPixelBuffer(), epoch: 1)

        #expect(decoder.inFlightDecodeBacklog() == 1)
        #expect(decoder.statsCollector.lastDecodedFrameTime == decodedBefore)
        #expect(decoder.secondsSinceLastPresentedFrame() == .infinity)
        #expect(!decoder.didFireFirstDecodedFrame)
    }

    @Test func droppedOutputWithAnImageDoesNotPresentOrAdvanceDecodedProgress() throws {
        let decoder = liveDecoder(format: StreamProtocol.VIDEO_FORMAT_H265)
        defer { decoder.teardown() }
        _ = decoder.reserveDecodeSlot(isIDR: false)
        #expect(decoder.beginSubmittedDecode(epoch: 0))

        deliver(decoder, status: noErr, image: try makeTaggedPixelBuffer(), flags: .frameDropped)

        #expect(decoder.inFlightDecodeBacklog() == 0)
        #expect(decoder.statsCollector.decoderDropCount() == 1)
        #expect(decoder.secondsSinceLastDecodedFrame() == .infinity)
        #expect(decoder.secondsSinceLastPresentedFrame() == .infinity)
        #expect(!decoder.didFireFirstDecodedFrame)
    }

    @Test func decodedOutputPresentsAndFiresTheFirstFrameOnce() async throws {
        let decoder = liveDecoder(format: StreamProtocol.VIDEO_FORMAT_H265_MAIN10)
        defer { decoder.teardown() }
        decoder.inFlightDecodes = 1
        decoder.decodeReservations[0] = VideoDecoder.DecodeReservations(submitted: 1)
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
