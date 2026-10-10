// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Samples the picture's brightness behind the stats HUD so the overlay can pick light or dark ink.
// Runs on the present path after the renderer has the frame, at most 4 Hz, luma plane only.

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

/// Cross-thread backdrop state, behind `VideoDecoder.backdropBox`.
struct HUDBackdropState {
    var rect: CGRect = .zero
    var overlayEnabled = false
    var lastSampleNanos: UInt64 = 0
    var luminance: Double?
}

/// A read-only view of a decoded frame's luma plane.
struct LumaPlane {
    let base: UnsafeRawPointer
    let bytesPerRow: Int
    let width: Int
    let height: Int
    /// 8, or 10 for samples stored in the high bits of 16 (`x420`).
    let bitDepth: Int
    let fullRange: Bool
    let isPQ: Bool
}

extension VideoDecoder {

    nonisolated static let backdropSampleIntervalNanos: UInt64 = 250_000_000
    nonisolated static let backdropGridColumns = 16
    nonisolated static let backdropGridRows = 8

    /// Normalized rect (origin top-left of the picture) to sample; `.zero` turns sampling off.
    var hudBackdropRect: CGRect {
        get { backdropBox.withLock { $0.rect } }
        set {
            backdropBox.withLock {
                $0.rect = newValue
                if newValue.isEmpty { $0.luminance = nil }
            }
        }
    }

    /// Latest mean relative luminance (0...1) inside `hudBackdropRect`, nil before a sample.
    var hudBackdropLuminance: Double? { backdropBox.withLock { $0.luminance } }

    nonisolated static func backdropSampleDue(now: UInt64, last: UInt64) -> Bool {
        last == 0 || now &- last >= backdropSampleIntervalNanos
    }

    /// Called after a frame reaches the renderer. One uncontended lock when idle; never waits.
    nonisolated func sampleHUDBackdrop(_ sampleBuffer: CMSampleBuffer) {
        let now = DispatchTime.now().uptimeNanoseconds
        let claimed: CGRect? = backdropBox.withLock { state in
            guard state.overlayEnabled, !state.rect.isEmpty,
                  Self.backdropSampleDue(now: now, last: state.lastSampleNanos) else { return nil }
            state.lastSampleNanos = now
            return state.rect
        }
        guard let rect = claimed,
              let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer),
              let luminance = Self.backdropLuminance(of: pixelBuffer, in: rect) else { return }
        backdropBox.withLock { $0.luminance = luminance }
    }

    nonisolated static func backdropLuminance(of pixelBuffer: CVPixelBuffer, in rect: CGRect) -> Double? {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard CVPixelBufferGetPlaneCount(pixelBuffer) >= 2,
              CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, 0) else { return nil }
        let transfer = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, nil)
        let plane = LumaPlane(
            base: UnsafeRawPointer(base),
            bytesPerRow: CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, 0),
            width: CVPixelBufferGetWidthOfPlane(pixelBuffer, 0),
            height: CVPixelBufferGetHeightOfPlane(pixelBuffer, 0),
            bitDepth: tenBitFormats.contains(format) ? 10 : 8,
            fullRange: fullRangeFormats.contains(format),
            isPQ: (transfer as? String) == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String))
        return meanLuminance(of: plane, in: rect)
    }

    private nonisolated static let tenBitFormats: Set<OSType> = [
        kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
        kCVPixelFormatType_444YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr10BiPlanarFullRange
    ]
    private nonisolated static let fullRangeFormats: Set<OSType> = [
        kCVPixelFormatType_420YpCbCr8BiPlanarFullRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange,
        kCVPixelFormatType_444YpCbCr8BiPlanarFullRange, kCVPixelFormatType_444YpCbCr10BiPlanarFullRange
    ]

    /// Mean relative luminance over a sparse grid inside `rect`, or nil when the rect misses the picture.
    nonisolated static func meanLuminance(of plane: LumaPlane, in rect: CGRect) -> Double? {
        let clipped = rect.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard !clipped.isNull, !clipped.isEmpty, plane.width > 0, plane.height > 0 else { return nil }
        let (cols, rows) = (backdropGridColumns, backdropGridRows)
        var total = 0.0
        for row in 0..<rows {
            let fy = clipped.minY + (Double(row) + 0.5) / Double(rows) * clipped.height
            let y = min(Int(fy * Double(plane.height)), plane.height - 1)
            for col in 0..<cols {
                let fx = clipped.minX + (Double(col) + 0.5) / Double(cols) * clipped.width
                let x = min(Int(fx * Double(plane.width)), plane.width - 1)
                total += relativeLuminance(code: lumaCode(plane, x: x, y: y), plane: plane)
            }
        }
        return total / Double(cols * rows)
    }

    private nonisolated static func lumaCode(_ plane: LumaPlane, x: Int, y: Int) -> Int {
        let row = y * plane.bytesPerRow
        if plane.bitDepth > 8 {
            let raw = plane.base.loadUnaligned(fromByteOffset: row + x * 2, as: UInt16.self)
            return Int(UInt16(littleEndian: raw) >> 6)
        }
        return Int(plane.base.load(fromByteOffset: row + x, as: UInt8.self))
    }

    /// SDR uses a 2.4 display gamma. PQ maps to nits over 203-nit reference white, so anything
    /// brighter reads as 1; non-constant-luminance Y' only approximates true luminance.
    private nonisolated static func relativeLuminance(code: Int, plane: LumaPlane) -> Double {
        let scale = Double(1 << (plane.bitDepth - 8))
        let (black, range) = plane.fullRange
            ? (0.0, Double((1 << plane.bitDepth) - 1)) : (16 * scale, 219 * scale)
        let signal = min(max((Double(code) - black) / range, 0), 1)
        guard plane.isPQ else { return pow(signal, 2.4) }
        let root = pow(signal, 1 / 78.84375)
        let nits = 10_000 * pow(max(root - 0.8359375, 0) / (18.8515625 - 18.6875 * root), 1 / 0.1593017578125)
        return min(nits / 203, 1)
    }
}
