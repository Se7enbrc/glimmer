//
//  HUDBackdropLuminanceTests.swift
//
//  The HUD backdrop sampler: range and bit-depth decoding, rect placement, and the 4 Hz gate.
//

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import Glimmer

struct HUDBackdropLuminanceTests {

    private static let width = 64
    private static let height = 32

    /// Runs `body` over a synthetic luma plane whose left and right halves hold the given codes.
    private func withPlane(
        left: UInt16, right: UInt16, bitDepth: Int = 8, fullRange: Bool = false, isPQ: Bool = false,
        _ body: (LumaPlane) -> Double?
    ) -> Double? {
        let bytesPerSample = bitDepth > 8 ? 2 : 1
        let bytesPerRow = Self.width * bytesPerSample + 16
        var bytes = [UInt8](repeating: 0, count: bytesPerRow * Self.height)
        for y in 0..<Self.height {
            for x in 0..<Self.width {
                let code = x < Self.width / 2 ? left : right
                let offset = y * bytesPerRow + x * bytesPerSample
                if bitDepth > 8 {
                    let stored = code << 6
                    bytes[offset] = UInt8(stored & 0xFF)
                    bytes[offset + 1] = UInt8(stored >> 8)
                } else {
                    bytes[offset] = UInt8(code)
                }
            }
        }
        return bytes.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return nil }
            return body(LumaPlane(
                base: base, bytesPerRow: bytesPerRow, width: Self.width, height: Self.height,
                bitDepth: bitDepth, fullRange: fullRange, isPQ: isPQ))
        }
    }

    private let whole = CGRect(x: 0, y: 0, width: 1, height: 1)

    private func mean(_ plane: LumaPlane, _ rect: CGRect) -> Double? {
        VideoDecoder.meanLuminance(of: plane, in: rect)
    }

    @Test func uniformBlackReadsZero() throws {
        let video = try #require(withPlane(left: 16, right: 16) { mean($0, whole) })
        let full = try #require(withPlane(left: 0, right: 0, fullRange: true) { mean($0, whole) })
        #expect(video < 0.001)
        #expect(full < 0.001)
    }

    @Test func uniformWhiteReadsOneInBothRanges() throws {
        let video = try #require(withPlane(left: 235, right: 235) { mean($0, whole) })
        let full = try #require(withPlane(left: 255, right: 255, fullRange: true) { mean($0, whole) })
        #expect(video > 0.999)
        #expect(full > 0.999)
    }

    @Test func rectPicksItsHalfOfASplitFrame() throws {
        let leftRect = CGRect(x: 0.05, y: 0.1, width: 0.4, height: 0.3)
        let rightRect = CGRect(x: 0.55, y: 0.6, width: 0.4, height: 0.3)
        let left = try #require(withPlane(left: 16, right: 235) { mean($0, leftRect) })
        let right = try #require(withPlane(left: 16, right: 235) { mean($0, rightRect) })
        let both = try #require(withPlane(left: 16, right: 235) { mean($0, whole) })
        #expect(left < 0.001)
        #expect(right > 0.999)
        #expect(abs(both - 0.5) < 0.01)
    }

    @Test func tenBitSamplesDecodeFromHighBits() throws {
        let black = try #require(withPlane(left: 64, right: 64, bitDepth: 10) { mean($0, whole) })
        let white = try #require(withPlane(left: 940, right: 940, bitDepth: 10) { mean($0, whole) })
        #expect(black < 0.001)
        #expect(white > 0.999)
    }

    @Test func pqClampsAtReferenceWhite() throws {
        // Full-range PQ code 0.58 is about 203 nits; 0.25 is about 5 nits.
        let bright = try #require(withPlane(left: 1023, right: 1023, bitDepth: 10, fullRange: true, isPQ: true) {
            mean($0, whole)
        })
        let dim = try #require(withPlane(left: 256, right: 256, bitDepth: 10, fullRange: true, isPQ: true) {
            mean($0, whole)
        })
        #expect(bright == 1)
        #expect(dim > 0.01 && dim < 0.05)
    }

    @Test func emptyOrOffPictureRectReadsNil() {
        #expect(withPlane(left: 235, right: 235) { mean($0, .zero) } == nil)
        #expect(withPlane(left: 235, right: 235) { mean($0, CGRect(x: 1.2, y: 0, width: 0.2, height: 0.2)) } == nil)
    }

    @Test func sampleGateAllowsFourPerSecond() {
        let interval = VideoDecoder.backdropSampleIntervalNanos
        #expect(VideoDecoder.backdropSampleDue(now: 5_000_000_000, last: 0))
        #expect(!VideoDecoder.backdropSampleDue(now: 1_000_000_000 + interval - 1, last: 1_000_000_000))
        #expect(VideoDecoder.backdropSampleDue(now: 1_000_000_000 + interval, last: 1_000_000_000))
        #expect(interval == 250_000_000)
    }
    // MARK: - Decoded pixel buffers

    private static let tenBit: Set<OSType> = [
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
    ]

    /// A bi-planar buffer whose luma plane holds `code` everywhere; 10-bit codes sit in the high bits.
    private func pixelBuffer(_ format: OSType, code: UInt16, pq: Bool = false) throws -> CVPixelBuffer {
        var buffer: CVPixelBuffer?
        let attrs = [kCVPixelBufferIOSurfacePropertiesKey: [:]] as CFDictionary
        #expect(CVPixelBufferCreate(nil, Self.width, Self.height, format, attrs, &buffer) == kCVReturnSuccess)
        let pixels = try #require(buffer)
        CVPixelBufferLockBaseAddress(pixels, [])
        defer { CVPixelBufferUnlockBaseAddress(pixels, []) }
        let base = try #require(CVPixelBufferGetBaseAddressOfPlane(pixels, 0))
        let rowBytes = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        for y in 0..<CVPixelBufferGetHeightOfPlane(pixels, 0) {
            for x in 0..<CVPixelBufferGetWidthOfPlane(pixels, 0) {
                if Self.tenBit.contains(format) {
                    base.storeBytes(of: (code << 6).littleEndian, toByteOffset: y * rowBytes + x * 2, as: UInt16.self)
                } else {
                    base.storeBytes(of: UInt8(code), toByteOffset: y * rowBytes + x, as: UInt8.self)
                }
            }
        }
        if pq {
            CVBufferSetAttachment(
                pixels, kCVImageBufferTransferFunctionKey, kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ,
                .shouldPropagate)
        }
        return pixels
    }

    private func luminance(_ format: OSType, code: UInt16, pq: Bool = false) throws -> Double? {
        VideoDecoder.backdropLuminance(of: try pixelBuffer(format, code: code, pq: pq), in: whole)
    }

    @Test func pixelFormatSelectsRangeAndBitDepth() throws {
        // Video-range white (235) is full scale only when the format says video range.
        let videoWhite = try #require(try luminance(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, code: 235))
        let fullAt235 = try #require(try luminance(kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, code: 235))
        #expect(videoWhite > 0.999)
        #expect(fullAt235 > 0.8 && fullAt235 < 0.9)
        // A 10-bit plane read as 8-bit would see the low byte of each sample.
        let tenBitWhite = try #require(try luminance(kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, code: 940))
        let tenBitBlack = try #require(try luminance(kCVPixelFormatType_420YpCbCr10BiPlanarFullRange, code: 0))
        #expect(tenBitWhite > 0.999)
        #expect(tenBitBlack < 0.001)
    }

    @Test func pqTransferAttachmentSwitchesToNits() throws {
        let format = kCVPixelFormatType_420YpCbCr10BiPlanarFullRange
        let sdr = try #require(try luminance(format, code: 256))
        let pq = try #require(try luminance(format, code: 256, pq: true))
        #expect(abs(sdr - pow(256.0 / 1023, 2.4)) < 0.001)
        #expect(pq > 0.01 && pq < 0.05)
    }

    @Test func singlePlaneBufferIsNotSampled() throws {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, Self.width, Self.height, kCVPixelFormatType_32BGRA, nil, &buffer)
        let bgra = try #require(buffer)
        #expect(VideoDecoder.backdropLuminance(of: bgra, in: whole) == nil)
    }

    private func sample(_ pixels: CVPixelBuffer) throws -> CMSampleBuffer {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: pixels, formatDescriptionOut: &format)
        var timing = CMSampleTimingInfo(duration: .invalid, presentationTimeStamp: .zero, decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(
            allocator: nil, imageBuffer: pixels, formatDescription: try #require(format),
            sampleTiming: &timing, sampleBufferOut: &sample)
        return try #require(sample)
    }

    @Test @MainActor func presentPathSamplesOnlyWithTheOverlayUpAndARect() throws {
        let decoder = VideoDecoder()
        let white = try sample(try pixelBuffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, code: 235))
        decoder.hudBackdropRect = whole
        decoder.sampleHUDBackdrop(white)
        #expect(decoder.hudBackdropLuminance == nil)

        decoder.statsOverlayEnabled = true
        decoder.sampleHUDBackdrop(white)
        #expect(try #require(decoder.hudBackdropLuminance) > 0.999)

        decoder.hudBackdropRect = .zero
        #expect(decoder.hudBackdropLuminance == nil)
        decoder.sampleHUDBackdrop(white)
        #expect(decoder.hudBackdropLuminance == nil)
    }

    @Test @MainActor func presentPathHoldsTheSampleUntilTheNextQuarterSecond() throws {
        let decoder = VideoDecoder()
        decoder.statsOverlayEnabled = true
        decoder.hudBackdropRect = whole
        let white = try sample(try pixelBuffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, code: 235))
        let black = try sample(try pixelBuffer(kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, code: 16))
        decoder.sampleHUDBackdrop(white)
        // A black frame straight after is inside the 250 ms window, so the reading stands.
        decoder.sampleHUDBackdrop(black)
        #expect(try #require(decoder.hudBackdropLuminance) > 0.999)

        decoder.statsOverlayEnabled = false
        #expect(decoder.hudBackdropLuminance == nil)
    }
}
