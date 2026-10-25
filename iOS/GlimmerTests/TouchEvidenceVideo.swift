// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

#if TOUCH_INPUT_EVIDENCE
import AVFoundation
import UIKit
@testable import Glimmer

@MainActor
final class TouchEvidenceVideo: NSObject {
    let surface = StreamSurface()
    private var frames: [CVPixelBuffer] = []
    private var format: CMVideoFormatDescription?
    private var link: CADisplayLink?
    private(set) var submitted = 0

    override init() {
        super.init()
        for offset in [200, 220] {
            var buffer: CVPixelBuffer?
            let attributes = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
            let created = CVPixelBufferCreate(nil, 1280, 720, kCVPixelFormatType_32BGRA, attributes, &buffer)
            guard created == kCVReturnSuccess,
                  let buffer else { continue }
            CVPixelBufferLockBaseAddress(buffer, [])
            if let bytes = CVPixelBufferGetBaseAddress(buffer) {
                let stride = CVPixelBufferGetBytesPerRow(buffer) / 4
                let pixels = bytes.assumingMemoryBound(to: UInt32.self)
                for row in 0..<720 {
                    for column in 0..<1280 {
                        let stripe = (offset..<offset + 40).contains(column)
                        pixels[row * stride + column] = stripe ? 0xFF789088 : 0xFF305860
                    }
                }
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            frames.append(buffer)
        }
        if let frame = frames.first {
            _ = CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: frame,
                                                             formatDescriptionOut: &format)
        }
    }

    func start() {
        let link = CADisplayLink(target: self, selector: #selector(present))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: 60, maximum: 60, preferred: 60)
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() { link?.invalidate(); link = nil; surface.displayLayer.sampleBufferRenderer.flush() }

    @objc private func present() {
        guard frames.count == 2, let format,
              surface.displayLayer.sampleBufferRenderer.isReadyForMoreMediaData else { return }
        let time = CMTime(seconds: CACurrentMediaTime(), preferredTimescale: 60000)
        var timing = CMSampleTimingInfo(duration: CMTime(value: 1, timescale: 60),
                                       presentationTimeStamp: time,
                                       decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: frames[submitted % 2],
            formatDescription: format, sampleTiming: &timing, sampleBufferOut: &sample)
        guard status == noErr, let sample else { return }
        if let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true)
            as? [NSMutableDictionary] {
            attachments.first?[kCMSampleAttachmentKey_DisplayImmediately] = true
        }
        surface.displayLayer.sampleBufferRenderer.enqueue(sample)
        submitted += 1
    }
}
#endif
