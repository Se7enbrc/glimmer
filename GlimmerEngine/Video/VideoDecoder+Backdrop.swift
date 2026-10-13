// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Samples the picture's brightness behind the stats HUD so the overlay can pick light or dark ink.
// Runs on the present path after the renderer has the frame, at most 4 Hz, luma plane only.

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

/// Cross-thread backdrop state, behind `VideoDecoder.backdropBox`.
package struct HUDBackdropState {
    package var rect: CGRect = .zero
    package var overlayEnabled = false
    package var lastSampleNanos: UInt64 = 0
    package var luminance: Double?
    package var pixelFormat: OSType?
    package var transfer: String?
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
    var isHLG = false
}

extension VideoDecoder {

    nonisolated static let backdropSampleIntervalNanos: UInt64 = 250_000_000
    nonisolated static let backdropGridColumns = 16
    nonisolated static let backdropGridRows = 8

    /// Normalized rect (origin top-left of the picture) to sample; `.zero` turns sampling off.
    package var hudBackdropRect: CGRect {
        get { backdropBox.withLock { $0.rect } }
        set {
            backdropBox.withLock {
                guard $0.rect != newValue else { return }
                $0.rect = newValue
                $0.luminance = nil
                $0.lastSampleNanos = 0
            }
        }
    }

    /// Latest mean relative luminance (0...1) inside `hudBackdropRect`, nil before a sample.
    package var hudBackdropLuminance: Double? { backdropBox.withLock { $0.luminance } }

    package var hudBackdropState: HUDBackdropState { backdropBox.withLock { $0 } }

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
        guard let rect = claimed, let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        let luminance = Self.backdropLuminance(of: pixelBuffer, in: rect)
        let transfer = CVBufferCopyAttachment(pixelBuffer, kCVImageBufferTransferFunctionKey, nil) as? String
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        backdropBox.withLock {
            // A layout change or hide must not publish a reading from the old region.
            guard $0.overlayEnabled, $0.rect == rect else { return }
            $0.luminance = luminance
            $0.pixelFormat = format
            $0.transfer = transfer
        }
    }

    nonisolated static func backdropLuminance(of pixelBuffer: CVPixelBuffer, in rect: CGRect) -> Double? {
        let format = CVPixelBufferGetPixelFormatType(pixelBuffer)
        guard eightBitFormats.contains(format) || tenBitFormats.contains(format),
              CVPixelBufferGetPlaneCount(pixelBuffer) >= 2,
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
            isPQ: (transfer as? String) == (kCVImageBufferTransferFunction_SMPTE_ST_2084_PQ as String),
            isHLG: (transfer as? String) == (kCVImageBufferTransferFunction_ITU_R_2100_HLG as String))
        return meanLuminance(of: plane, in: rect)
    }

    private nonisolated static let eightBitFormats: Set<OSType> = [
        kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
        kCVPixelFormatType_444YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_444YpCbCr8BiPlanarFullRange
    ]

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

    /// HDR uses BT.2100 reference rendering relative to 203-nit diffuse white.
    /// Non-constant-luminance Y' approximates luminance; macOS owns final display tone mapping.
    private nonisolated static func relativeLuminance(code: Int, plane: LumaPlane) -> Double {
        let scale = Double(1 << (plane.bitDepth - 8))
        let (black, range) = plane.fullRange
            ? (0.0, Double((1 << plane.bitDepth) - 1)) : (16 * scale, 219 * scale)
        let signal = min(max((Double(code) - black) / range, 0), 1)
        if plane.isHLG {
            let scene = signal <= 0.5 ? signal * signal / 3
                : (exp((signal - 0.55991073) / 0.17883277) + 0.28466892) / 12
            return min(1_000 * pow(scene, 1.2) / 203, 1)
        }
        guard plane.isPQ else { return pow(signal, 2.4) }
        let root = pow(signal, 1 / 78.84375)
        let nits = 10_000 * pow(max(root - 0.8359375, 0) / (18.8515625 - 18.6875 * root), 1 / 0.1593017578125)
        return min(nits / 203, 1)
    }
}
