// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AppKit
import AVFoundation
import CoreMedia
import CoreVideo
import Testing
@testable import GlimmerEngine
@testable import Glimmer

@MainActor
struct VideoBoundaryTests {
    @Test func rendererDiagnosticGenerationRejectsReplacedAndDetachedLayers() {
        let decoder = VideoDecoder()
        let first = AVSampleBufferDisplayLayer()
        decoder.attach(to: first)
        let firstGeneration = decoder.attachmentGeneration(for: first.sampleBufferRenderer)
        #expect(firstGeneration != nil)
        let replacement = AVSampleBufferDisplayLayer()
        decoder.attach(to: replacement)
        #expect(decoder.attachmentGeneration(for: first.sampleBufferRenderer) == nil)
        #expect(decoder.attachmentGeneration(for: replacement.sampleBufferRenderer) != firstGeneration)
        decoder.teardown()
        #expect(decoder.attachmentGeneration(for: replacement.sampleBufferRenderer) == nil)
    }

    @Test func screenRebindRejectsObsoleteTicksAndUnchangedScreensKeepTheirLink() throws {
        let fixture = DisplayFixture()
        let pacer = FramePacer(stats: StatsCollector(), configuredFps: 120)
        pacer.start(display: fixture.display)
        defer { pacer.stop() }
        let first = try #require(pacer.displayLink)
        let generation = pacer.bindingGeneration
        pacer.screenDidChange()
        #expect(pacer.displayLink === first)
        #expect(fixture.binds == 1)
        fixture.identity = "second"
        pacer.screenDidChange()
        #expect(pacer.displayLink !== first)
        #expect(fixture.binds == 2)
        let ticks = pacer.liveness.tickCount
        pacer.handleTick(target: 2, duration: 1.0 / 120, timestamp: 1, generation: generation)
        #expect(pacer.liveness.tickCount == ticks)
        pacer.handleTick(target: 2, duration: 1.0 / 120, timestamp: 1, generation: pacer.bindingGeneration)
        #expect(pacer.liveness.tickCount == ticks + 1)
    }

    @Test func detachedFactoryCancelsAssistAndReturningToSameScreenRebinds() async throws {
        let fixture = DisplayFixture()
        let pacer = FramePacer(stats: StatsCollector(), configuredFps: 120)
        pacer.start(display: fixture.display)
        defer { pacer.stop() }
        let first = try #require(pacer.displayLink)
        let timer = try pacer.pacingQueue.sync {
            pacer.lock.lock()
            pacer.tickDeficit.deficitModeActive = true
            pacer.lock.unlock()
            pacer.reconcileDeficitTimer()
            return try #require(pacer.tickDeficit.deficitTimer)
        }
        fixture.identity = "none"
        fixture.attached = false
        pacer.screenDidChange()
        await pacer.pacingQueue.drainForTest()
        #expect(pacer.displayLink == nil)
        #expect(timer.isCancelled)
        #expect(pacer.pacingQueue.sync { pacer.tickDeficit.deficitTimer == nil })
        fixture.identity = "first"
        fixture.attached = true
        pacer.screenDidChange()
        #expect(pacer.displayLink != nil)
        #expect(pacer.displayLink !== first)
        #expect(fixture.binds == 3)
    }

    @Test func detachedAndRestartedPacerRejectsLateWork() throws {
        let fixture = DisplayFixture()
        let pacer = FramePacer(stats: StatsCollector(), configuredFps: 120)
        pacer.start(display: fixture.display)
        let generation = pacer.bindingGeneration
        pacer.stop()
        pacer.handleTick(target: 2, duration: 1.0 / 120, timestamp: 1, generation: generation)
        #expect(pacer.liveness.lastTickHostTime.isNaN)
        fixture.attached = false
        pacer.start(display: fixture.display)
        #expect(pacer.displayLink == nil)
        fixture.attached = true
        pacer.start(display: fixture.display)
        defer { pacer.stop() }
        let buffer = try VideoDecoderLifecycleTests.readySample()
        pacer.submit(buffer, hostPTS: CMTime(value: 1, timescale: 90_000))
        let queued = pacer.queue.count
        pacer.releaseDueFrame(targetTimestamp: 3, vsyncInterval: 1.0 / 120,
                              tickScanout: 3, generation: generation)
        #expect(pacer.queue.count == queued)
        #expect(pacer.liveness.releaseCount == 0)
    }

    @Test func deferredColorProbeCannotConfigureReplacementLayer() async throws {
        let decoder = VideoDecoder()
        decoder.attach(to: AVSampleBufferDisplayLayer())
        defer { decoder.teardown() }
        let buffer = try VideoDecoderLifecycleTests.readySample()
        let pixels = try #require(CMSampleBufferGetImageBuffer(buffer))
        let color = decoder.resolveColorDescription(for: pixels, controlHDR: true)
        decoder.resolvedColor.withLock { $0 = color }
        var logs = 0
        decoder.colorProbeLog = { _, _ in logs += 1 }
        let probe = try #require(decoder.beginColorProbe(pixels, color: color, controlHDR: true))
        let task = try #require(decoder.finishColorProbe(probe, pixelBuffer: pixels))
        let replacement = AVSampleBufferDisplayLayer()
        replacement.setDynamicRange(high: false)
        decoder.attach(to: replacement)
        replacement.setDynamicRange(high: false)
        logs = 0
        await task.value
        #expect(replacement.dynamicRangeLabel == "standard")
        #expect(logs == 0)
    }

    @Test func attachingReplacementRestoresResolvedHDR() throws {
        let decoder = VideoDecoder()
        decoder.attach(to: AVSampleBufferDisplayLayer())
        defer { decoder.teardown() }
        let pixels = try makeTaggedPixelBuffer(
            primaries: kCVImageBufferColorPrimaries_ITU_R_2020,
            transfer: kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ)
        let color = decoder.resolveColorDescription(for: pixels, controlHDR: true)
        try #require(color.isHDR)
        decoder.resolvedColor.withLock { $0 = color }
        let replacement = AVSampleBufferDisplayLayer()
        replacement.setDynamicRange(high: false)
        decoder.attach(to: replacement)
        #expect(replacement.dynamicRangeLabel == hdrRangeLabel)
        #expect(decoder.isHDRActive)
    }

    @Test func detachedLayerRejectsQueuedRecovery() async {
        let decoder = VideoDecoder()
        let backend = InputRecordingBackend()
        decoder.setBackend(backend)
        decoder.attach(to: AVSampleBufferDisplayLayer())
        #expect(decoder.recoverPresentPathFromRenderQueue(reason: "old-layer"))
        decoder.teardown()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(backend.idrRequests == 0)
        let pending = decoder.presentRecoveryPending.load(ordering: .acquiring)
        #expect(!pending)
    }

    @Test func detachedLayerRejectsDelayedFirstFrameCallback() async {
        let decoder = VideoDecoder()
        decoder.attach(to: AVSampleBufferDisplayLayer())
        decoder.isStreaming = true
        var callbacks = 0
        decoder.onFirstDecodedFrame = { callbacks += 1 }
        decoder.scheduleFirstDecodedFrame()
        decoder.teardown()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { continuation.resume() }
        }
        #expect(callbacks == 0)
    }

    @Test func liveReplacementPreservesPendingFirstFrameNotification() async {
        let decoder = VideoDecoder()
        decoder.attach(to: AVSampleBufferDisplayLayer())
        defer { decoder.teardown() }
        decoder.isStreaming = true
        decoder.didFireFirstDecodedFrame = true
        var callbacks = 0
        decoder.onFirstDecodedFrame = { callbacks += 1 }
        decoder.scheduleFirstDecodedFrame()
        decoder.attach(to: AVSampleBufferDisplayLayer())
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { continuation.resume() }
        }
        #expect(callbacks == 1)
    }

    @Test func stopAndRestartRejectsPreviousFirstFrameNotification() async {
        let decoder = VideoDecoder()
        decoder.attach(to: AVSampleBufferDisplayLayer())
        defer { decoder.teardown() }
        decoder.isStreaming = true
        var callbacks = 0
        decoder.onFirstDecodedFrame = { callbacks += 1 }
        decoder.scheduleFirstDecodedFrame()
        decoder.stop()
        decoder.start()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { continuation.resume() }
        }
        #expect(callbacks == 0)
    }

    @Test func publicConnectionBindsDecoderRecoveryAndStoppedBackendRejectsAttachment() async throws {
        let decoder = VideoDecoder()
        let connection = StreamConnection(video: decoder, onEvent: { _, _ in })
        let bound = try #require(decoder.backend as? NativeBackend)
        #expect(bound.videoSink === decoder)
        #expect(bound.hdrMetadata() == nil)
        decoder.refreshHDRMetadataFromHost()
        await connection.stop()
        #expect(bound.videoSink == nil)
        let replacement = VideoDecoder()
        bound.attachVideoSink(replacement)
        #expect(replacement.backend == nil)
        #expect(bound.videoSink == nil)
        decoder.teardown()
        replacement.teardown()
    }

    @Test func restartedPacerRejectsQueuedDrainAndObsoleteAssistBeat() async throws {
        let pacer = FramePacer(stats: StatsCollector(), configuredFps: 120)
        pacer.running = true
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        pacer.pacingQueue.async {
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
        }
        defer { release.signal() }
        try #require(await entered.waitAsync(for: .seconds(2)) == .success)
        let generation = pacer.bindingGeneration
        pacer.drainHeadDirectly(reason: "obsolete")
        pacer.stop()
        pacer.running = true
        pacer.tickDeficit.deficitModeActive = true
        pacer.submit(try VideoDecoderLifecycleTests.readySample(), hostPTS: CMTime(value: 1, timescale: 90_000))
        pacer.deficitTimerFired(generation: generation)
        #expect(pacer.queue.count == 1)
        pacer.tickDeficit.deficitModeActive = false
        release.signal()
        await pacer.pacingQueue.drainForTest()
        #expect(pacer.queue.count == 1)
        #expect(pacer.liveness.releaseCount == 0)
        pacer.stop()
    }

    @Test func rebindRenewsAssistTimerAndCancelsPreviousGeneration() throws {
        let pacer = FramePacer(stats: StatsCollector(), configuredFps: 120)
        pacer.running = true
        pacer.displayBound = true
        pacer.tickDeficit.deficitModeActive = true
        try pacer.pacingQueue.sync {
            pacer.reconcileDeficitTimer()
            let old = try #require(pacer.tickDeficit.deficitTimer)
            pacer.lock.lock()
            pacer.bindingGeneration &+= 1
            let generation = pacer.bindingGeneration
            pacer.lock.unlock()
            pacer.reconcileDeficitTimer()
            #expect(old.isCancelled)
            #expect(pacer.tickDeficit.deficitTimerGeneration == generation)
        }
        pacer.stop()
    }

    @Test func finalTeardownReleasesDisplayFactoryAndRebuildOwner() {
        let decoder = VideoDecoder()
        var owner: DisplayOwner? = DisplayOwner()
        weak let retained = owner
        var display = owner.map { owner in
            PacerDisplay(makeLink: { [owner] _, _ in _ = owner; return nil }, screen: {
                PacerScreen(identity: "none", maximumHz: 0, minimumHz: nil, scale: 1)
            }, tickOffMain: { false }, prepareTickThread: {})
        }
        if let display { decoder.startPacing(display: display, configuredFps: 60) }
        decoder.rebuildDisplayLayerHook = { [owner] in _ = owner; return nil }
        decoder.displayInfo = { [owner] in _ = owner; return nil }
        decoder.onFirstDecodedFrame = { [owner] in _ = owner }
        decoder.onHDRActiveChanged = { [owner] _ in _ = owner }
        owner = nil
        display = nil
        decoder.disablePacingFallbackToDirect(reason: "test")
        #expect(retained != nil)
        decoder.teardown()
        #expect(retained == nil)
        #expect(decoder.pacingDisplay == nil)
        #expect(decoder.rebuildDisplayLayerHook == nil)
    }

    private final class DisplayOwner {}

    @MainActor private final class DisplayFixture {
        let view = NSView()
        var identity = "first"
        var attached = true
        var binds = 0
        var display: PacerDisplay {
            PacerDisplay(makeLink: { [self] target, selector in
                binds += 1
                return attached ? view.displayLink(target: target, selector: selector) : nil
            }, screen: { [self] in
                PacerScreen(identity: identity, maximumHz: 120, minimumHz: nil, scale: 2)
            }, tickOffMain: { false }, prepareTickThread: {})
        }
    }
}
