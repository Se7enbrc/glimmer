// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

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
        case stop, hide, hideThenNewerFrame
    }

    @Test(arguments: Interruption.allCases)
    func queuedSubmitRespectsStopAndSuppression(_ interruption: Interruption) async throws {
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
        let first = try emptySampleBuffer()
        pacer.submit(first, hostPTS: CMTime(value: 0, timescale: 90_000))
        #expect(pacer.queue.isEmpty)
        var newest = first

        switch interruption {
        case .stop:
            pacer.stop()
        case .hide:
            pacer.setPresentSuppressed(true)
        case .hideThenNewerFrame:
            pacer.setPresentSuppressed(true)
            newest = try emptySampleBuffer()
            pacer.submit(newest, hostPTS: CMTime(value: 750, timescale: 90_000))
        }
        release.signal()
        await pacer.pacingQueue.drainForTest()

        #expect(presents.withLock { $0 } == 0)
        #expect(pacer.liveness.releaseCount == 0)
        if interruption == .stop {
            #expect(pacer.queue.isEmpty)
        } else {
            #expect(pacer.queue.count == 1)
            #expect(pacer.queue.first.map { ObjectIdentifier($0.sampleBuffer) } == ObjectIdentifier(newest))
        }
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
    @Test func releasedDecodedImageDisplaysImmediatelyWithoutRetiming() throws {
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
    }
}
