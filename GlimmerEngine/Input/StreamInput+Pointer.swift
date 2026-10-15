// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

extension StreamInput {
    /// Relative host pixels, positive right/down. Capture adapters own the view-points to pixels conversion.
    public func movePointer(dx: Double, dy: Double, capturedAt: TimeInterval) {
        InputTimingContext.begin(source: .mouse, timestamp: capturedAt)
        defer { InputTimingContext.end() }
        core.withLock {
            defer { scheduleReconciliation() }
            guard accepts(capturedAt), dx.isFinite, dy.isFinite, core.flushReleases() else { return }
            core.sendRelativePointer(dx: dx, dy: dy)
        }
    }

    public func setPointerButton(_ button: PointerButton, pressed: Bool, capturedAt: TimeInterval) {
        InputTimingContext.begin(source: .mouse, timestamp: capturedAt)
        defer { InputTimingContext.end() }
        core.withLock {
            defer { scheduleReconciliation() }
            guard accepts(capturedAt) else { return }
            core.updatePhysicalMouseButton(button.rawValue, pressed: pressed)
        }
    }

    /// Precise deltas are native pixel deltas; wheel deltas are lines. Positive Y scrolls up, X right.
    /// Uses the existing 0.1 pixels-to-lines conversion and 120-unit notch quantizer.
    public func scroll(x: Double, y: Double, precise: Bool, capturedAt: TimeInterval) {
        InputTimingContext.begin(source: .mouse, timestamp: capturedAt)
        defer { InputTimingContext.end() }
        core.withLock {
            defer { scheduleReconciliation() }
            guard accepts(capturedAt), x.isFinite, y.isFinite, core.flushReleases() else { return }
            core.sendScroll(x: x, y: y, precise: precise)
        }
    }

    public func endScroll() { core.resetScroll() }
}
