// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  VideoDecoderLifecycleTests.swift
//
//  Setup sizing, start/stop/cleanup, the sink's unit walk, the overlay surface, teardown resets,
//  pacing bring-up and fallback, and the RTP clock recovered from a sample's PTS.
//

import AppKit
import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import Glimmer

@MainActor
struct VideoDecoderLifecycleTests {

    // MARK: Setup and lifecycle

    /// The in-flight pool is a time budget (~250 ms, ceiling ~375 ms) with floors for slow streams.
    @Test(arguments: [(Int32(0), 15, 22), (60, 15, 22), (120, 30, 45), (240, 60, 90)])
    func setupScalesTheDecodePoolToTheFrameRate(fps: Int32, bound: Int, ceiling: Int) {
        let decoder = VideoDecoder()
        _ = decoder.handleSetup(videoFormat: 0, width: 3_840, height: 2_160, redrawRate: fps)
        #expect(decoder.maxInFlightDecodes == bound)
        #expect(decoder.maxInFlightDecodeCeiling == ceiling)
    }

    @Test func setupRejectsAnUnknownCodecButKeepsTheStreamShape() {
        let decoder = VideoDecoder()
        #expect(decoder.setup(videoFormat: 0x10_0000, width: 2_560, height: 1_440, redrawRate: 144) == -1)
        #expect(decoder.streamWidth == 2_560)
        #expect(decoder.streamHeight == 1_440)
        #expect(decoder.streamFps == 144)
    }

    @Test func startAndStopGateTheStreamAndResetTheConnection() {
        let decoder = VideoDecoder()
        decoder.statsCollector.lastDecodedFrameTime = CACurrentMediaTime()
        decoder.start()
        #expect(decoder.isStreaming)
        #expect(decoder.secondsSinceLastDecodedFrame() == .infinity)

        decoder.presentSuppressedLock.lock()
        decoder._decodeGated = true
        decoder.presentSuppressedLock.unlock()
        decoder.stop()
        #expect(!decoder.isStreaming)
        #expect(!decoder.decodeGated)
        decoder.teardown()
    }

    @Test func cleanupForgetsParameterSetsAndTheBacklog() throws {
        let decoder = VideoDecoder()
        decoder.spsData = Data([1])
        decoder.ppsData = Data([2])
        decoder.vpsData = Data([3])
        decoder.cachedHDRFormatDescription = try VideoDecoderHDRTests.formatDescription()
        decoder.inFlightDecodes = 3
        decoder.lastVtDecodeFailed = true

        decoder.cleanup()

        #expect(decoder.spsData == nil && decoder.ppsData == nil && decoder.vpsData == nil)
        #expect(decoder.cachedHDRFormatDescription == nil)
        #expect(decoder.inFlightDecodeBacklog() == 0)
        #expect(!decoder.lastVtDecodeFailed)
    }

    /// A P-frame with no session to decode on frees its slot, counts a discard and resyncs once.
    @Test func frameWithoutASessionIsAbandonedAndResyncs() async {
        let decoder = VideoDecoder()
        decoder.isStreaming = true
        let result = decoder.decodeAssembledFrame(
            pictureData: Data([0]), newSps: nil, newPps: nil, newVps: nil, isIDR: false, rtpTimestamp: 0, totalLength: 1)
        #expect(result == StreamProtocol.DR_OK)
        await decoder.decodeQueue.drainForTest()
        #expect(decoder.inFlightDecodeBacklog() == 0)
        #expect(decoder.statsCollector.decoderDropCount() == 1)
        #expect(decoder.decodeGateDisposition(isIDR: false) == .resyncToIdr)
    }

    // MARK: Sink

    @Test func sinkAdvertisesRFIForHEVCAndAV1Only() {
        let decoder = VideoDecoder()
        #expect(decoder.capabilities & StreamProtocol.CAPABILITY_REFERENCE_FRAME_INVALIDATION_HEVC != 0)
        #expect(decoder.capabilities & StreamProtocol.CAPABILITY_REFERENCE_FRAME_INVALIDATION_AV1 != 0)
        #expect(decoder.capabilities & StreamProtocol.CAPABILITY_REFERENCE_FRAME_INVALIDATION_AVC == 0)
    }

    private func unit(type: Int32, buffers: [DecodeBuffer]) -> DecodeUnit {
        DecodeUnit(frameNumber: 1, frameType: type, fullLength: 12, frameHostProcessingLatency: 0,
                   receiveTimeUs: 0, enqueueTimeUs: 0, presentationTimeUs: 0, rtpTimestamp: 0,
                   hdrActive: false, colorspace: 0, buffers: buffers)
    }

    /// A unit's parameter sets reach the decoder stripped of start codes; nothing is taken after stop.
    @Test func sinkSplitsParameterSetsOutOfTheUnit() async {
        let decoder = VideoDecoder()
        decoder.streamVideoFormat = StreamProtocol.VIDEO_FORMAT_H264
        let idr = unit(type: StreamProtocol.FRAME_TYPE_IDR, buffers: [
            DecodeBuffer(kind: .sps, data: Data([0, 0, 0, 1, 0x67, 0xFF])),
            DecodeBuffer(kind: .pps, data: Data([0, 0, 1, 0x68, 0xEE])),
            DecodeBuffer(kind: .picData, data: Data([0, 0, 0, 1, 0x65])),
            DecodeBuffer(kind: .picData, data: Data([0x88]))
        ])

        #expect(decoder.submitDecodeUnit(idr) == StreamProtocol.DR_OK)
        #expect(decoder.statsCollector.receivedFrames == 0)

        decoder.isStreaming = true
        #expect(decoder.submitDecodeUnit(idr) == StreamProtocol.DR_OK)
        await decoder.decodeQueue.drainForTest()
        #expect(decoder.statsCollector.receivedFrames == 1)
        #expect(decoder.spsData == Data([0x67, 0xFF]))
        #expect(decoder.ppsData == Data([0x68, 0xEE]))
        #expect(decoder.vpsData == nil)
    }

    // MARK: Overlay surface

    @Test func snapshotCarriesTheNegotiatedStream() {
        let decoder = VideoDecoder()
        decoder.streamVideoFormat = StreamProtocol.VIDEO_FORMAT_AV1_MAIN10
        decoder.streamFps = 120
        decoder.setNegotiatedBitrateKbps(150_000)
        decoder.setActiveAudioConfigLabel("7.1 surround")
        let snap = decoder.statsSnapshot()
        #expect(snap.videoCodec == "AV1")
        #expect(snap.configuredFps == 120)
        #expect(snap.negotiatedBitrateMbps == 150)
        #expect(snap.audioConfigDescription == "7.1 surround")
        #expect(VideoDecoder().statsSnapshot().negotiatedBitrateMbps == nil)
    }

    @Test func codecNamesPreferTheNewestCodecBit() {
        #expect(VideoDecoder.codecDisplayName(for: StreamProtocol.VIDEO_FORMAT_H264) == "H.264")
        #expect(VideoDecoder.codecDisplayName(for: StreamProtocol.VIDEO_FORMAT_H265_REXT10_444) == "HEVC")
        #expect(VideoDecoder.codecDisplayName(for: StreamProtocol.VIDEO_FORMAT_AV1_MAIN8
                                                  | StreamProtocol.VIDEO_FORMAT_H265) == "AV1")
        #expect(VideoDecoder.codecDisplayName(for: 0) == nil)
        #expect(VideoDecoder.codecLabel(for: 0) == "unknown")
    }

    @Test func overlayToggleNotifiesAndClearsTheBackdropSample() {
        let decoder = VideoDecoder()
        var changes: [Bool] = []
        decoder.onStatsOverlayEnabledChanged = { changes.append($0) }
        decoder.toggleStatsOverlay()
        #expect(decoder.backdropBox.withLock { $0.overlayEnabled })
        decoder.backdropBox.withLock { $0.luminance = 0.5 }
        decoder.statsOverlayEnabled = true
        decoder.toggleStatsOverlay()
        #expect(changes == [true, false])
        #expect(decoder.backdropBox.withLock { $0.luminance } == nil)
    }

    /// The next session must start cold: an SDR stream after HDR must not inherit PQ state.
    @Test func teardownClearsEveryHDRCache() {
        let decoder = VideoDecoder()
        decoder.attach(to: AVSampleBufferDisplayLayer())
        decoder.hdrEnabled = true
        decoder.hdrMetadataStore.publish(HDRMetadata(mdcv: Data([1]), contentLightLevel: nil))
        decoder.lastColorSpaceKey = "itur_2100_PQ"
        decoder.lastColorSpace = CGColorSpace(name: CGColorSpace.itur_2100_PQ)
        decoder.didLogFirstPixelBufferProbe = true
        decoder.didConfigureLayerOnce = true
        decoder.didFireFirstDecodedFrame = true
        decoder.isStreaming = true

        decoder.teardown()

        #expect(!decoder.isStreaming)
        #expect(!decoder.hdrEnabled)
        #expect(decoder.hdrMetadataStore.snapshot == .empty)
        #expect(decoder.lastColorSpaceKey == nil && decoder.lastColorSpace == nil)
        #expect(!decoder.didLogFirstPixelBufferProbe && !decoder.didConfigureLayerOnce)
        #expect(!decoder.didFireFirstDecodedFrame)
        #expect(decoder.displayLayer == nil && decoder.sampleBufferRenderer == nil)
    }

    // MARK: Pacing

    /// A pacer built while hidden starts suppressed, and a re-enable warms up before cutting over.
    @Test func pacingBringUpInheritsStateAndFallsBackToDirect() throws {
        let decoder = VideoDecoder()
        defer { decoder.teardown() }
        let view = NSView()
        #expect(!decoder.reenablePacing(configuredFps: 120))
        decoder.presentSuppressedLock.lock()
        decoder._presentSuppressed = true
        decoder.presentSuppressedLock.unlock()

        decoder.startPacing(drivingView: view, configuredFps: 120)
        let first = try #require(decoder.framePacer)
        #expect(first.running && first.presentSuppressed)
        #expect(!first.tickDeficit.warmingUp)
        #expect(decoder.pacingDrivingView === view)
        #expect(!decoder.reenablePacing(configuredFps: 120))

        decoder.disablePacingFallbackToDirect(reason: "test")
        #expect(decoder.framePacer == nil)
        #expect(!first.running)

        #expect(decoder.reenablePacing(configuredFps: 120))
        let rebuilt = try #require(decoder.framePacer)
        #expect(rebuilt !== first)
        #expect(rebuilt.tickDeficit.warmingUp)
    }

    /// A pacer's release reaches the renderer only through presentFrame's teardown gate.
    @Test func pacerReleaseRoutesThroughThePresentGate() throws {
        let decoder = VideoDecoder()
        decoder.attach(to: AVSampleBufferDisplayLayer())
        defer { decoder.teardown() }
        decoder.startPacing(drivingView: NSView(), configuredFps: 60)
        let release = try #require(decoder.framePacer?.willPresent)
        let sample = try Self.readySample()

        #expect(!release(sample))
        decoder.isStreaming = true
        #expect(release(sample))
        #expect(decoder.secondsSinceLastPresentedFrame() < 60)
    }

    @Test func presentRecoveryFlushesAndAsksForOneKeyframeWithoutRebuilding() {
        let decoder = VideoDecoder()
        decoder.attach(to: AVSampleBufferDisplayLayer())
        defer { decoder.teardown() }
        let backend = InputRecordingBackend()
        decoder.setBackend(backend)
        var rebuilds = 0
        decoder.rebuildDisplayLayerHook = { rebuilds += 1; return nil }

        decoder.recoverPresentPath(reason: "test")

        #expect(backend.idrRequests == 1)
        #expect(rebuilds == 0)
    }

    // MARK: RTP clock

    @Test func rtpTimestampComesBackFromThePTS() {
        #expect(VideoDecoder.rtpTimestamp(from: CMTime(value: 123_456, timescale: 90_000)) == 123_456)
        #expect(VideoDecoder.rtpTimestamp(from: CMTime(value: 2, timescale: 1)) == 180_000)
        #expect(VideoDecoder.rtpTimestamp(from: CMTime(value: 0x1_0000_0005, timescale: 90_000)) == 5)
        #expect(VideoDecoder.rtpTimestamp(from: .invalid) == 0)
        #expect(VideoDecoder.rtpTimestamp(from: .positiveInfinity) == 0)
    }

    static func readySample() throws -> CMSampleBuffer {
        let image = try makeTaggedPixelBuffer(format: kCVPixelFormatType_32BGRA)
        var format: CMVideoFormatDescription?
        try #require(CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: nil, imageBuffer: image, formatDescriptionOut: &format) == noErr)
        var timing = CMSampleTimingInfo(
            duration: .invalid, presentationTimeStamp: CMTime(value: 1, timescale: 90_000), decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        try #require(CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: image, formatDescription: try #require(format),
            sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
        return try #require(sample)
    }
}
