// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AVFoundation
import Testing
import UIKit
@testable import Glimmer

@Suite(.serialized)
@MainActor
struct StreamDisplayRenderTests {
    @Test(.timeLimit(.minutes(3)), arguments: [CGSize(width: 640, height: 480), CGSize(width: 700, height: 300)])
    func fittedPictureKeepsEveryEdge(size: CGSize) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
            .first { $0.session.role == .windowApplication })
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        window.rootViewController = root
        window.isHidden = false
        let surface = StreamSurface(frame: CGRect(origin: .zero, size: size))
        root.view.addSubview(surface)
        surface.layoutIfNeeded()
        defer { window.isHidden = true; window.rootViewController = nil }
        let ready = AsyncStream<Void>.makeStream()
        let observer = NotificationCenter.default.addObserver(
            forName: .AVSampleBufferDisplayLayerReadyForDisplayDidChange, object: surface.displayLayer, queue: nil
        ) { _ in ready.continuation.yield(()) }
        defer { NotificationCenter.default.removeObserver(observer); ready.continuation.finish() }
        surface.displayLayer.sampleBufferRenderer.enqueue(try sample())
        if !surface.displayLayer.isReadyForDisplay {
            for await _ in ready.stream where surface.displayLayer.isReadyForDisplay { break }
        }
        let shape = "\(Int(size.width))x\(Int(size.height))"
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.displayLayer.videoGravity = .resizeAspect
        CATransaction.commit()
        try record(surface, name: "external-fit-\(shape)")
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        surface.displayLayer.videoGravity = .resizeAspectFill
        CATransaction.commit()
        try record(surface, name: "external-previous-crop-\(shape)")
    }

    private func record(_ surface: StreamSurface, name: String) throws {
        CATransaction.flush()
        var rendered = false
        let image = UIGraphicsImageRenderer(bounds: surface.bounds).image { _ in
            rendered = surface.drawHierarchy(in: surface.bounds, afterScreenUpdates: true)
        }
        #expect(rendered)
        Attachment.record(Array(try #require(image.pngData())), named: "\(name).png")
    }

    private func sample() throws -> CMSampleBuffer {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        try #require(CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA,
                                        attributes, &buffer) == kCVReturnSuccess)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let context = try #require(CGContext(data: CVPixelBufferGetBaseAddress(pixels), width: 640, height: 360,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(pixels),
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue))
        context.setFillColor(UIColor.darkGray.cgColor)
        context.fill(CGRect(x: 0, y: 0, width: 640, height: 360))
        let corners: [(UIColor, CGRect)] = [
            (.red, CGRect(x: 0, y: 0, width: 80, height: 80)),
            (.green, CGRect(x: 560, y: 0, width: 80, height: 80)),
            (.blue, CGRect(x: 0, y: 280, width: 80, height: 80)),
            (.yellow, CGRect(x: 560, y: 280, width: 80, height: 80))
        ]
        for (color, rect) in corners { context.setFillColor(color.cgColor); context.fill(rect) }
        var format: CMVideoFormatDescription?
        try #require(CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels,
            formatDescriptionOut: &format) == noErr)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        try #require(CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: pixels,
            formatDescription: try #require(format), sampleTiming: &timing, sampleBufferOut: &sample) == noErr)
        return try #require(sample)
    }
}
