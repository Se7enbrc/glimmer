// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import CoreMedia
import CoreVideo
@testable import GlimmerEngine
import Testing
import UIKit
@testable import Glimmer

extension NativeUIRenderTests {
    @Test(arguments: [CGSize(width: 667, height: 375), CGSize(width: 956, height: 440)], [false, true])
    func bitrateTransitionKeepsSurfaceAndOnlyShowsDelayedRecovery(size: CGSize, dark: Bool) async throws {
        let id = UUID()
        var pause: (@MainActor @Sendable () -> Void)?
        let model = StreamSessionModel(launch: testLaunch(), makePlayback: { _, _, quiesce in
            pause = quiesce
            return StreamPlayback(id: id, events: AsyncStream { _ in }, start: {}, stop: {}, screenChanged: {})
        })
        let controller = StreamViewController(model: model, close: {})
        controller.loadViewIfNeeded()
        model.start(surface: controller.surface)
        model.receive(.init(sessionID: id, attemptID: UUID(), event: .firstFrame))
        model.resumeInput()
        let layer = controller.surface.displayLayer
        let configuration = StreamConnection.Configuration(width: 64, height: 64, fps: 60,
                                                            bitrateKbps: 20_000, videoFormats: .h264)
        let decoder = VideoDecoder(configuration: configuration, displayInfo: { nil })
        decoder.attach(to: layer)
        defer { decoder.teardown() }
        var captureError: Error?
        let name = "bitrate-\(Int(size.width))-\(dark ? "dark" : "light")"
        try await recordController(controller, name: "\(name)-complete", size: size, dark: dark, prepare: {
            do {
                layer.sampleBufferRenderer.enqueue(try syntheticFrame())
                for phase in ["before", "quiet", "indicator", "after"] {
                    if phase == "quiet" {
                        pause?()
                        decoder.retainImageForReconnect.store(true, ordering: .releasing)
                        decoder.flushRenderer(layer.sampleBufferRenderer)
                    }
                    if phase == "indicator" {
                        model.receive(.init(sessionID: id, attemptID: UUID(), event: .reconnecting))
                    }
                    if phase == "after" { model.receive(.init(sessionID: id, attemptID: UUID(), event: .reconnected)) }
                    #expect(controller.surface.displayLayer === layer)
                    #expect(layer.superlayer === controller.surface.layer)
                    #expect(model.inputFocused == (phase == "before" || phase == "after"))
                    try await Task.sleep(for: .milliseconds(200))
                    try recordPhase(controller.view, name: "\(name)-\(phase)")
                }
            } catch { captureError = error }
        })
        if let captureError { throw captureError }
        model.stop()
        await model.waitUntilStopped()
    }

    private func syntheticFrame() throws -> CMSampleBuffer {
        var image: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        try #require(CVPixelBufferCreate(kCFAllocatorDefault, 64, 64, kCVPixelFormatType_32BGRA,
                                        attributes, &image) == kCVReturnSuccess)
        let pixels = try #require(image)
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let base = try #require(CVPixelBufferGetBaseAddress(pixels))
        let stride = CVPixelBufferGetBytesPerRow(pixels)
        for row in 0..<64 {
            let line = base.advanced(by: row * stride).assumingMemoryBound(to: UInt32.self)
            for column in 0..<64 {
                line[column] = (row / 8 + column / 8).isMultiple(of: 2) ? 0xFF613CD9 : 0xFF24394B
            }
        }
        var format: CMVideoFormatDescription?
        try #require(CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault, imageBuffer: pixels, formatDescriptionOut: &format) == noErr)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        try #require(CMSampleBufferCreateReadyWithImageBuffer(allocator: kCFAllocatorDefault, imageBuffer: pixels,
            formatDescription: try #require(format), sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
        let result = try #require(sample)
        VideoDecoder.markForImmediateDisplay(result)
        return result
    }
}
