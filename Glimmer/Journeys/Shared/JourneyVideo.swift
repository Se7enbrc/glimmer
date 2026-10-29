// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

#if DEBUG
import AVFoundation
import CoreGraphics

@MainActor
final class JourneyVideo {
    private let layer: AVSampleBufferDisplayLayer
    private var sequence = 0

    init(layer: AVSampleBufferDisplayLayer) { self.layer = layer }

    func draw() throws {
        var buffer: CVPixelBuffer?
        let attributes = [kCVPixelBufferCGImageCompatibilityKey: true,
                          kCVPixelBufferCGBitmapContextCompatibilityKey: true] as CFDictionary
        guard CVPixelBufferCreate(nil, 640, 360, kCVPixelFormatType_32BGRA, attributes, &buffer) == kCVReturnSuccess,
              let buffer else { throw Failure.buffer }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let context = CGContext(data: CVPixelBufferGetBaseAddress(buffer), width: 640, height: 360,
            bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer), space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue)
        else { throw Failure.buffer }
        for (index, color) in [CGColor(red: 0, green: 1, blue: 1, alpha: 1),
                              CGColor(red: 1, green: 0, blue: 1, alpha: 1),
                              CGColor(red: 1, green: 1, blue: 0, alpha: 1),
                              CGColor(red: 0, green: 0, blue: 1, alpha: 1)].enumerated() {
            context.setFillColor(color)
            context.fill(CGRect(x: index * 160, y: 0, width: 160, height: 360))
        }
        context.setFillColor(CGColor(gray: 1, alpha: 1))
        context.fill(CGRect(x: (sequence * 32) % 600, y: 160, width: 40, height: 40))
        sequence += 1
        var format: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: buffer,
            formatDescriptionOut: &format) == noErr, let format else { throw Failure.buffer }
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        guard CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: buffer,
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample) == noErr,
              let sample else { throw Failure.buffer }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true) {
            let values = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(values, Unmanaged.passUnretained(kCMSampleAttachmentKey_DisplayImmediately).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        layer.sampleBufferRenderer.enqueue(sample)
    }

    var ready: Bool { layer.isReadyForDisplay }
    enum Failure: Error { case buffer }
}
#endif
