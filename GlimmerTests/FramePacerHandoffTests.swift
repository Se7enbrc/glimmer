// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

@testable import GlimmerEngine
import AVFoundation
import CoreMedia
import CoreVideo
import Foundation
import os
import QuartzCore
import Testing
@testable import Glimmer

@MainActor
struct FramePacerHandoffTests {
    enum Interruption: CaseIterable {
        case stop, restart, hide, hideThenNewerFrame, clear, clearThenNewerFrame
    }

    @Test(arguments: Interruption.allCases, [false, true])
    func queuedSubmitRespectsLifecycle(_ interruption: Interruption, warm: Bool) async throws {
        let pacer = FramePacer(stats: StatsCollector(), configuredFps: 120)
        let presents = OSAllocatedUnfairLock(initialState: 0)
        pacer.willPresent = { _ in presents.withLock { $0 += 1 }; return true }
        pacer.running = true
        pacer.refreshTelemetry.lastRefreshIntervalSeconds = 1.0 / 120
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        pacer.pacingQueue.async {
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
        }
        defer { release.signal() }
        try #require(await entered.waitAsync(for: .seconds(2)) == .success)
        let scanout = CACurrentMediaTime() + 0.05
        pacer.liveness.lastTickTargetMediaTime = scanout
        pacer.lastPresentMediaTime = scanout - 1.0 / 120
        if warm { pacer.armWarmHandover() }
        let first = try emptySampleBuffer()
        pacer.submit(first, hostPTS: CMTime(value: 0, timescale: 90_000))
        #expect(pacer.queue.isEmpty)
        var newest = first

        switch interruption {
        case .stop:
            pacer.stop()
        case .restart:
            pacer.stop()
            pacer.running = true
        case .hide:
            pacer.setPresentSuppressed(true)
        case .hideThenNewerFrame:
            pacer.setPresentSuppressed(true)
            newest = try emptySampleBuffer()
            pacer.submit(newest, hostPTS: CMTime(value: 750, timescale: 90_000))
        case .clear, .clearThenNewerFrame:
            pacer.clearQueue(reason: "test discontinuity")
            if interruption == .clearThenNewerFrame {
                pacer.lock.withLock { pacer.tickDeficit.warmingUp = false }
                newest = try emptySampleBuffer()
                pacer.submit(newest, hostPTS: CMTime(value: 750, timescale: 90_000))
            }
        }
        release.signal()
        await pacer.pacingQueue.drainForTest()

        #expect(presents.withLock { $0 } == 0)
        #expect(pacer.liveness.releaseCount == 0)
        if interruption == .stop || interruption == .restart || interruption == .clear {
            #expect(pacer.queue.isEmpty)
        } else {
            #expect(pacer.queue.count == 1)
            #expect(pacer.queue.first.map { ObjectIdentifier($0.sampleBuffer) } == ObjectIdentifier(newest))
        }
    }

    @Test func warmHandoverCutoverKeepsFramesOnOnePresentationQueue() async throws {
        let pacer = try makeTestPacer()
        pacer.armWarmHandover()
        let presented = recordPresents(pacer)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        pacer.pacingQueue.async {
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
        }
        defer { release.signal() }
        try #require(await entered.waitAsync(for: .seconds(2)) == .success)
        let first = try emptySampleBuffer()
        let second = try emptySampleBuffer()
        pacer.submit(first, hostPTS: CMTime(value: 0, timescale: 90_000))
        #expect(presented.withLock { $0.isEmpty })
        pacer.lock.withLock {
            pacer.tickDeficit.warmingUp = false
            pacer.resetCadenceBaseLocked()
        }
        pacer.submit(second, hostPTS: CMTime(value: 750, timescale: 90_000))
        pacer.pacingQueue.async {
            pacer.releaseDueFrame(targetTimestamp: 10, vsyncInterval: 1.0 / 120, tickScanout: 10)
        }
        release.signal()
        await pacer.pacingQueue.drainForTest()
        #expect(presented.withLock { $0 } == [ObjectIdentifier(first), ObjectIdentifier(second)])
    }

    @Test func discontinuityFlushWaitsForAnAlreadyRunningPresentation() async throws {
        let pacer = try makeTestPacer()
        pacer.armWarmHandover()
        let events = OSAllocatedUnfairLock(initialState: [String]())
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let flushed = DispatchSemaphore(value: 0)
        let barrierOwnedQueue = OSAllocatedUnfairLock(initialState: false)
        pacer.willPresent = { _ in
            events.withLock { $0.append("present began") }
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
            events.withLock { $0.append("present returned") }
            return true
        }
        defer { release.signal() }
        pacer.submit(try emptySampleBuffer(), hostPTS: CMTime(value: 0, timescale: 90_000))
        try #require(await entered.waitAsync(for: .seconds(2)) == .success)
        DispatchQueue.global().async {
            pacer.clearQueue(reason: "test discontinuity") {
                barrierOwnedQueue.withLock {
                    $0 = DispatchQueue.getSpecific(key: pacer.pacingQueueKey) == true
                }
                events.withLock { $0.append("flush") }
            }
            flushed.signal()
        }
        #expect(events.withLock { !$0.contains("flush") })
        release.signal()
        try #require(await flushed.waitAsync(for: .seconds(2)) == .success)
        #expect(barrierOwnedQueue.withLock { $0 })
        #expect(events.withLock { $0 } == ["present began", "present returned", "flush"])
    }

    @Test func discontinuityBarrierCanRunFromThePresentationQueue() async throws {
        let pacer = try makeTestPacer(queued: 1)
        let finished = DispatchSemaphore(value: 0)
        let discarded = OSAllocatedUnfairLock(initialState: -1)
        pacer.pacingQueue.async {
            let count = pacer.clearQueue(reason: "nested barrier") {}
            discarded.withLock { $0 = count }
            finished.signal()
        }
        try #require(await finished.waitAsync(for: .seconds(2)) == .success)
        #expect(discarded.withLock { $0 } == 1)
        #expect(pacer.queue.isEmpty)
    }

    @Test(arguments: [Int32(120), 240])
    func queuedOldTickCannotOvertakeANewerSubmitReservation(fps: Int32) async throws {
        let pacer = FramePacer(stats: StatsCollector(), configuredFps: fps)
        pacer.running = true
        let presented = recordPresents(pacer)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        pacer.pacingQueue.async {
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
        }
        defer { release.signal() }
        try #require(await entered.waitAsync(for: .seconds(2)) == .success)
        let vsync = 1.0 / Double(fps)
        let scanout = CACurrentMediaTime() + 0.5
        let oldTick = scanout - vsync
        pacer.pacingQueue.async {
            pacer.releaseDueFrame(
                targetTimestamp: oldTick, vsyncInterval: vsync, tickScanout: oldTick, generation: 0)
        }
        pacer.refreshTelemetry.lastRefreshIntervalSeconds = vsync
        pacer.liveness.lastTickTargetMediaTime = scanout
        pacer.lastPresentMediaTime = scanout - 2 * vsync
        let first = try emptySampleBuffer()
        let second = try emptySampleBuffer()
        pacer.submit(first, hostPTS: CMTime(value: 0, timescale: 90_000))
        try #require(pacer.queue.isEmpty)
        pacer.submit(second, hostPTS: CMTime(value: 750, timescale: 90_000))
        try #require(pacer.queue.count == 1)

        release.signal()
        await pacer.pacingQueue.drainForTest()
        #expect(presented.withLock { $0 } == [ObjectIdentifier(first)])
        #expect(pacer.queue.first.map { ObjectIdentifier($0.sampleBuffer) } == ObjectIdentifier(second))
        #expect(pacer.lastPresentMediaTime == scanout)
        #expect(pacer.stats.presentationLateDropCount() == 0)

        let next = scanout + vsync
        pacer.releaseDueFrame(targetTimestamp: next, vsyncInterval: vsync, tickScanout: next)
        #expect(presented.withLock { $0 } == [ObjectIdentifier(first), ObjectIdentifier(second)])
    }

    @Test(arguments: [false, true])
    func stalledDirectHandoffKeepsOnlyTheNewestPendingFrame(warm: Bool) async throws {
        let pacer = try makeTestPacer()
        if warm { pacer.armWarmHandover() }
        let presented = recordPresents(pacer)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        pacer.pacingQueue.async {
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
        }
        defer { release.signal() }
        try #require(await entered.waitAsync(for: .seconds(2)) == .success)
        var samples: [WeakSample] = []
        for index in 0..<256 {
            try autoreleasepool {
                let sample = try emptySampleBuffer()
                samples.append(WeakSample(sample))
                if !warm {
                    let target = CACurrentMediaTime() + 10 + Double(index) / 120
                    pacer.lock.withLock {
                        pacer.refreshTelemetry.lastRefreshIntervalSeconds = 1.0 / 120
                        pacer.liveness.lastTickTargetMediaTime = target
                        pacer.lastPresentMediaTime = target - 1.0 / 120
                    }
                }
                pacer.submit(sample, hostPTS: CMTime(value: Int64(index) * 750, timescale: 90_000))
            }
        }
        #expect(samples.dropLast().allSatisfy { $0.value == nil })
        let newest = try #require(samples.last?.value)
        #expect(pacer.stats.presentationLateDropCount() == 255)
        #expect(pacer.queue.isEmpty)
        release.signal()
        await pacer.pacingQueue.drainForTest()
        #expect(presented.withLock { $0 } == [ObjectIdentifier(newest)])
    }

    @Test(arguments: [false, true])
    func retirementReleasesPendingFrameBeforePresentationQueueResumes(stop: Bool) async throws {
        let pacer = try makeTestPacer()
        pacer.armWarmHandover()
        let presented = recordPresents(pacer)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        pacer.pacingQueue.async {
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
        }
        defer { release.signal() }
        try #require(await entered.waitAsync(for: .seconds(2)) == .success)
        let old = try autoreleasepool {
            let sample = try emptySampleBuffer()
            pacer.submit(sample, hostPTS: CMTime(value: 0, timescale: 90_000))
            return WeakSample(sample)
        }
        if stop {
            pacer.stop()
            pacer.running = true
            pacer.armWarmHandover()
        } else {
            pacer.clearQueue(reason: "test pending retirement")
        }
        #expect(old.value == nil)
        let newest = try emptySampleBuffer()
        pacer.submit(newest, hostPTS: CMTime(value: 750, timescale: 90_000))
        release.signal()
        await pacer.pacingQueue.drainForTest()
        #expect(presented.withLock { $0 } == [ObjectIdentifier(newest)])
    }

    @Test func lateDecodedFrameCannotReplaceANewerPendingHandoff() async throws {
        let pacer = try makeTestPacer()
        pacer.armWarmHandover()
        let presented = recordPresents(pacer)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        pacer.pacingQueue.async {
            entered.signal()
            _ = release.wait(timeout: .now() + 5)
        }
        defer { release.signal() }
        try #require(await entered.waitAsync(for: .seconds(2)) == .success)
        let newest = try emptySampleBuffer()
        pacer.submit(newest, hostPTS: CMTime(value: 1500, timescale: 90_000))
        pacer.submit(try emptySampleBuffer(), hostPTS: CMTime(value: 750, timescale: 90_000))
        release.signal()
        await pacer.pacingQueue.drainForTest()
        #expect(presented.withLock { $0 } == [ObjectIdentifier(newest)])
        #expect(pacer.stats.presentationLateDropCount() == 1)
    }

    private final class WeakSample {
        weak var value: CMSampleBuffer?
        init(_ sample: CMSampleBuffer) { value = sample }
    }

    private func emptySampleBuffer() throws -> CMSampleBuffer {
        var buffer: CMSampleBuffer?
        CMSampleBufferCreate(
            allocator: nil, dataBuffer: nil, dataReady: true, makeDataReadyCallback: nil,
            refcon: nil, formatDescription: nil, sampleCount: 0, sampleTimingEntryCount: 0,
            sampleTimingArray: nil, sampleSizeEntryCount: 0, sampleSizeArray: nil,
            sampleBufferOut: &buffer)
        return try #require(buffer)
    }
}

@MainActor
struct VideoRendererTimingTests {
    @Test func newFrameAndGovernorRepaintsPreservePTSButCountOnlyNewFrames() throws {
        let decoder = VideoDecoder()
        let layer = AVSampleBufferDisplayLayer()
        decoder.attach(to: layer)
        decoder.isStreaming = true
        defer { decoder.teardown() }

        var image: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey as String: [:]] as CFDictionary
        #expect(CVPixelBufferCreate(nil, 2, 2, kCVPixelFormatType_32BGRA, attributes, &image) == kCVReturnSuccess)
        let pixelBuffer = try #require(image)
        var format: CMVideoFormatDescription?
        #expect(CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: nil, imageBuffer: pixelBuffer, formatDescriptionOut: &format) == noErr)
        let formatDescription = try #require(format)
        let hostPTS = CMTime(value: 53_207, timescale: 90_000)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: hostPTS, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        #expect(CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: pixelBuffer, formatDescription: formatDescription,
            sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
        let buffer = try #require(sample)

        #expect(layer.controlTimebase == nil)
        try #require(decoder.presentFrame(buffer))
        let attachments = try #require(CMSampleBufferGetSampleAttachmentsArray(
            buffer, createIfNecessary: false) as? [[String: Any]])
        let entry = try #require(attachments.first)
        #expect(entry[kCMSampleAttachmentKey_DisplayImmediately as String] as? Bool == true)
        #expect(CMSampleBufferGetPresentationTimeStamp(buffer) == hostPTS)
        #expect(CMSampleBufferGetOutputPresentationTimeStamp(buffer) == hostPTS)
        #expect(CMSampleBufferGetImageBuffer(buffer) === pixelBuffer)
        #expect(decoder.statsCollector.renderedFrames == 1)
        for _ in 0..<3 { decoder.repaintFrameForGovernor(buffer) }
        #expect(decoder.statsCollector.renderedFrames == 1)
        #expect(CMSampleBufferGetPresentationTimeStamp(buffer) == hostPTS)
        #expect(CMSampleBufferGetImageBuffer(buffer) === pixelBuffer)
    }
}
