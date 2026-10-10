//
//  HUDBackdropLuminanceTests.swift
//
//  The HUD backdrop sampler: range and bit-depth decoding, rect placement, and the 4 Hz gate.
//

import CoreGraphics
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
}
