// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  VideoDecoderSuppressionTests.swift
//
//  The hidden-window ladder: suppression edges, the decode gate and who owns the refocus
//  keyframe, plus the layer-stall observers that self-heal the present path.
//

@testable import GlimmerEngine
import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import Glimmer

@MainActor
struct VideoDecoderSuppressionTests {

    private func decoder(with backend: InputRecordingBackend) -> VideoDecoder {
        let decoder = VideoDecoder()
        decoder.attach(to: AVSampleBufferDisplayLayer())
        decoder.setBackend(backend)
        decoder.isStreaming = true
        return decoder
    }

    /// Stands in for the 2 s gate timer firing, without waiting for it.
    private func engageGate(_ decoder: VideoDecoder) {
        decoder.presentSuppressedLock.lock()
        decoder._decodeGated = true
        decoder._awaitingResyncIdr = true
        decoder.presentSuppressedLock.unlock()
    }

    private func submit(_ decoder: VideoDecoder, idr: Bool) -> Int32 {
        decoder.decodeAssembledFrame(pictureData: Data([0]), newSps: nil, newPps: nil, newVps: nil,
                                     isIDR: idr, rtpTimestamp: 0, totalLength: 1)
    }

    /// Hiding mirrors into the pacer and the gap judge and arms the gate; showing again
    /// undoes both and asks for exactly one keyframe, however often the edge repeats.
    @Test func edgesMirrorStateAndRefocusAsksForOneKeyframe() {
        let backend = InputRecordingBackend()
        let decoder = decoder(with: backend)
        defer { decoder.teardown() }
        let pacer = FramePacer(stats: decoder.statsCollector, configuredFps: 120)
        decoder.framePacer = pacer

        decoder.setPresentSuppressed(true)
        decoder.setPresentSuppressed(true)
        #expect(decoder.presentSuppressed)
        #expect(pacer.presentSuppressed)
        #expect(decoder.statsCollector.gapJudgingExcluded)
        #expect(decoder.decodeGateTimer != nil)
        #expect(backend.idrRequests == 0)
        #expect(decoder.rendererPresentationState == .init(generation: 1, suppressed: true))

        decoder.setPresentSuppressed(false)
        decoder.setPresentSuppressed(false)
        #expect(!decoder.presentSuppressed)
        #expect(!pacer.presentSuppressed)
        #expect(!decoder.statsCollector.gapJudgingExcluded)
        #expect(decoder.decodeGateTimer == nil)
        #expect(backend.idrRequests == 1)
        #expect(decoder.rendererPresentationState == .init(generation: 2, suppressed: false))
    }

    @Test func suppressionEdgesRecordPredicateInputsWithoutIdentifyingData() throws {
        let decoder = VideoDecoder(now: { 3_000_000_000 })
        defer { decoder.teardown() }
        let generation = UUID()
        var visibility = VideoDecoder.PresentationVisibility(reason: .occlusionChanged)
        visibility.windowVisible = true
        visibility.minimized = false
        visibility.occlusionVisible = false
        visibility.occlusionState = 0
        visibility.revealing = true
        visibility.alphaZero = false
        visibility.miniPlayer = true
        visibility.appActive = false
        visibility.fullScreen = true
        visibility.fullScreenTransition = .exiting
        decoder.setPresentSuppressed(true, visibility: visibility, sessionGeneration: generation)
        decoder.setPresentSuppressed(true, visibility: visibility, sessionGeneration: generation)
        visibility.reason = .coverReturnCompleted
        decoder.setPresentSuppressed(false, visibility: visibility, sessionGeneration: generation)
        decoder.setPresentSuppressed(false, visibility: visibility, sessionGeneration: generation)
        let entries = LogStore.shared.snapshot().filter { $0.message.contains(generation.uuidString) }
        #expect(entries.count == 2)
        for (index, entry) in entries.enumerated() {
            let json = try #require(entry.message.split(separator: " ", maxSplits: 2).last)
            let row = try #require(JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
            #expect(row["event"] as? String == "presentation_suppression")
            #expect(row["suppressed"] as? Bool == (index == 0))
            #expect(row["reason"] as? String == (index == 0 ? "occlusion_changed" : "cover_return_completed"))
            #expect(row["session_generation"] as? String == generation.uuidString)
            #expect(row["presentation_generation"] as? UInt64 == UInt64(index + 1))
            #expect(row["t_ms"] as? Double == 3000)
            #expect(row["window_visible"] as? Bool == true)
            #expect(row["minimized"] as? Bool == false)
            #expect(row["occlusion_visible"] as? Bool == false)
            #expect(row["occlusion_state"] as? UInt64 == 0)
            #expect(row["revealing"] as? Bool == true)
            #expect(row["alpha_zero"] as? Bool == false)
            #expect(row["mini_player"] as? Bool == true)
            #expect(row["app_active"] as? Bool == false)
            #expect(row["full_screen"] as? Bool == true)
            #expect(row["full_screen_transition"] as? String == "exiting")
            #expect(row.count == 16)
            #expect(entry.redactedMessage == nil)
        }
    }

    /// After a gated span the resync latch owns the refocus keyframe: no second request,
    /// and the first P-frame routes the depacketizer to wait for an IDR.
    @Test func gatedRefocusLeavesTheKeyframeToTheResync() {
        let backend = InputRecordingBackend()
        let decoder = decoder(with: backend)
        defer { decoder.teardown() }
        decoder.setPresentSuppressed(true)
        engageGate(decoder)
        #expect(decoder.decodeGated)

        decoder.setPresentSuppressed(false)

        #expect(!decoder.decodeGated)
        #expect(decoder.secondsSinceDecodeGateLifted() < 60)
        #expect(backend.idrRequests == 0)
        #expect(submit(decoder, idr: false) == StreamProtocol.DR_NEED_IDR)
        #expect(decoder.decodeGateDisposition(isIDR: false) == .feed(epoch: 0))
    }

    /// Gated AUs never reach a slot or VideoToolbox, and a gated IDR doesn't count as fed.
    @Test func gatedFramesDropBeforeAnyDecodeWork() {
        let decoder = decoder(with: InputRecordingBackend())
        defer { decoder.teardown() }
        engageGate(decoder)

        #expect(submit(decoder, idr: true) == StreamProtocol.DR_OK)
        #expect(submit(decoder, idr: false) == StreamProtocol.DR_OK)
        #expect(decoder.inFlightDecodeBacklog() == 0)
        #expect(decoder.statsCollector.decoderDropCount() == 0)

        decoder.clearDecodeGateForConnectionStop()
        #expect(decoder.decodeGateDisposition(isIDR: true) == .feed(epoch: 1))
    }

    /// A PC-side stop while gated unblocks the watchdog; with no gate it only drops the latch.
    @Test func connectionStopClearsTheGateAndTheLatch() {
        let gated = VideoDecoder()
        engageGate(gated)
        gated.clearDecodeGateForConnectionStop()
        #expect(!gated.decodeGated)
        #expect(gated.secondsSinceDecodeGateLifted() < 60)
        #expect(gated.decodeGateDisposition(isIDR: false) == .feed(epoch: 0))

        let ungated = VideoDecoder()
        #expect(ungated.armResyncAfterDecodeError(epoch: 0))
        ungated.clearDecodeGateForConnectionStop()
        #expect(ungated.secondsSinceDecodeGateLifted() == .infinity)
        #expect(ungated.decodeGateDisposition(isIDR: false) == .feed(epoch: 0))
    }

    @Test func resyncArmsOncePerEpoch() {
        let decoder = VideoDecoder()
        #expect(decoder.armResyncAfterDecodeError(epoch: 0))
        #expect(!decoder.armResyncAfterDecodeError(epoch: 0))
        #expect(decoder.decodeGateDisposition(isIDR: true) == .feed(epoch: 1))
        #expect(!decoder.armResyncAfterDecodeError(epoch: 0))
        #expect(decoder.armResyncAfterDecodeError(epoch: 1))
    }

    @Test func teardownStandsTheGateDown() {
        let decoder = decoder(with: InputRecordingBackend())
        decoder.setPresentSuppressed(true)
        engageGate(decoder)

        decoder.teardown()

        #expect(decoder.decodeGateTimer == nil)
        #expect(!decoder.decodeGated)
        #expect(decoder.decodeGateDisposition(isIDR: false) == .feed(epoch: 0))
    }

    /// A reconnect while hidden restores what the connect edge reset; a visible one leaves it.
    @Test func connectEdgeReappliesSuppressionOnlyWhileHidden() async throws {
        let visible = VideoDecoder()
        visible.reapplySuppressionAtConnect()
        #expect(!visible.statsCollector.gapJudgingExcluded)

        let hidden = decoder(with: InputRecordingBackend())
        defer { hidden.teardown() }
        hidden.setPresentSuppressed(true)
        hidden.cancelDecodeGateTimer()
        hidden.statsCollector.setGapJudgingExcluded(false)

        hidden.reapplySuppressionAtConnect()

        #expect(hidden.statsCollector.gapJudgingExcluded)
        for _ in 0..<200 where hidden.decodeGateTimer == nil {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(hidden.decodeGateTimer != nil)
        #expect(visible.decodeGateTimer == nil)
    }

    /// A backlog that fills because nothing presents is benign while hidden: no keyframe,
    /// and the pacer collapses to its newest frame. Visible, the same overflow resyncs.
    @Test func hiddenBacklogOverflowDropsWithoutAKeyframe() throws {
        let decoder = decoder(with: InputRecordingBackend())
        defer { decoder.teardown() }
        let pacer = FramePacer(stats: decoder.statsCollector, configuredFps: 120)
        pacer.running = true
        decoder.framePacer = pacer
        for value in [0, 750] {
            pacer.submit(try sampleBuffer(), hostPTS: CMTime(value: Int64(value), timescale: 90_000))
        }
        try #require(pacer.queue.count == 2)
        decoder.inFlightDecodes = decoder.maxInFlightDecodeCeiling
        decoder.decodeReservations[0] = VideoDecoder.DecodeReservations(queued: decoder.maxInFlightDecodeCeiling)

        decoder.presentSuppressedLock.lock()
        decoder._presentSuppressed = true
        decoder.presentSuppressedLock.unlock()
        #expect(submit(decoder, idr: false) == StreamProtocol.DR_OK)
        #expect(pacer.queue.count == 1)
        #expect(decoder.statsCollector.decoderDropCount() == 1)

        decoder.presentSuppressedLock.lock()
        decoder._presentSuppressed = false
        decoder.presentSuppressedLock.unlock()
        #expect(submit(decoder, idr: false) == StreamProtocol.DR_NEED_IDR)
        #expect(decoder.inFlightDecodeBacklog() == decoder.maxInFlightDecodeCeiling)
    }

    // MARK: Layer-stall observers

    @Test func observersFollowTheAttachedLayer() {
        let decoder = VideoDecoder()
        decoder.attach(to: AVSampleBufferDisplayLayer())
        #expect(decoder.layerStallObservers.count == 2)
        let rebuilt = AVSampleBufferDisplayLayer()
        decoder.attach(to: rebuilt)
        #expect(decoder.layerStallObservers.count == 2)
        #expect(decoder.displayLayer === rebuilt)
        decoder.teardown()
        #expect(decoder.layerStallObservers.isEmpty)
        #expect(decoder.displayLayer == nil)
    }

    /// A decode failure on the attached layer self-heals with a keyframe; another layer's
    /// failure, or a requires-flush change that didn't latch, does nothing.
    @Test func failedToDecodeOnTheAttachedLayerRequestsAKeyframe() async throws {
        let backend = InputRecordingBackend()
        let decoder = decoder(with: backend)
        defer { decoder.teardown() }
        let layer = try #require(decoder.displayLayer)
        let center = NotificationCenter.default

        center.post(name: .AVSampleBufferDisplayLayerFailedToDecode, object: AVSampleBufferDisplayLayer())
        center.post(name: AVSampleBufferVideoRenderer.requiresFlushToResumeDecodingDidChangeNotification,
                    object: layer.sampleBufferRenderer)
        await DispatchQueue.main.drainForTest()
        #expect(backend.idrRequests == 0)

        center.post(name: .AVSampleBufferDisplayLayerFailedToDecode, object: layer)
        for _ in 0..<200 where backend.idrRequests == 0 {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(backend.idrRequests == 1)
    }

    private func sampleBuffer() throws -> CMSampleBuffer {
        var buffer: CMSampleBuffer?
        CMSampleBufferCreate(
            allocator: nil, dataBuffer: nil, dataReady: true, makeDataReadyCallback: nil,
            refcon: nil, formatDescription: nil, sampleCount: 0, sampleTimingEntryCount: 0,
            sampleTimingArray: nil, sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &buffer)
        return try #require(buffer)
    }
}
