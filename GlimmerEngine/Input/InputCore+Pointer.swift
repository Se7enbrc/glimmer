// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

extension InputCore {
    package func resetPointerMotion() { withLock { pointerResidual = .zero } }

    package func sendRelativePointer(dx: Double, dy: Double) {
        withLock {
            guard snapshot.ready, dx.isFinite, dy.isFinite, flushReleases() else { return }
            pointerResidual += SIMD2(dx, dy)
            let x = Self.pointerDelta(pointerResidual.x)
            let y = Self.pointerDelta(pointerResidual.y)
            guard x != 0 || y != 0 else { return }
            pointerResidual -= SIMD2(Double(x), Double(y))
            record("LiSendMouseMoveEvent", backend?.sendMouseMove(dx: x, dy: y) ?? -2)
        }
    }

    private static func pointerDelta(_ value: Double) -> Int16 {
        Int16(min(Double(Int16.max), max(Double(Int16.min), value.rounded(.towardZero))))
    }

    package func sendAbsolutePointer(viewPoint: CGPoint, viewSize: CGSize, streamPixelSize: CGSize,
                                     captureSync: Bool = false) {
        withLock {
            guard snapshot.ready, let point = PointerMapping.streamPoint(
                viewPoint: viewPoint, viewSize: viewSize, streamPixelSize: streamPixelSize) else { return }
            let result = backend?.sendMousePosition(x: point.x, y: point.y, refW: point.refW, refH: point.refH) ?? -2
            record(captureSync ? "LiSendMousePositionEvent(capture-sync)" : "LiSendMousePositionEvent", result)
        }
    }

    /// Native precise pixels or wheel lines; wire quantization and residuals have one owner.
    @discardableResult
    package func sendScroll(x: Double, y: Double, precise: Bool, ended: Bool = false)
        -> (unitsY: Int, sentX: Int16, sentY: Int16) {
        withLock {
            guard snapshot.ready, x.isFinite, y.isFinite else { return (0, 0, 0) }
            defer { if ended { scrollQuantizer.reset() } }
            let scale = precise ? 0.1 : 1.0
            let unitsY = Self.scrollUnits(y * scale * 120)
            let unitsX = Self.scrollUnits(x * scale * 120)
            let sentY = Int16(clamping: scrollQuantizer.consumeVertical(unitsY, precise: precise))
            let sentX = Int16(clamping: scrollQuantizer.consumeHorizontal(unitsX, precise: precise))
            if sentY != 0 { record("LiSendHighResScrollEvent", backend?.sendScroll(sentY) ?? -2) }
            if sentX != 0 { record("LiSendHighResHScrollEvent", backend?.sendHScroll(sentX) ?? -2) }
            return (unitsY, sentX, sentY)
        }
    }

    package func resetScroll() { withLock { scrollQuantizer.reset() } }

    private static func scrollUnits(_ value: Double) -> Int {
        // Leave room for the quantizer's sub-notch residual before Int arithmetic.
        Int(min(Double(Int.max / 2), max(Double(Int.min / 2), value.rounded())))
    }
}
