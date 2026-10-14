// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Game mode preserves per-finger PC touch events; mouse mode uses the same snapshots as a trackpad.

import GlimmerEngine
import Foundation
import GameController

extension InputForwarder {

    // MARK: - Touchpad surface forwarding

    typealias TouchpadFinger = ControllerTouchpadFinger
    typealias TouchpadState = ControllerTouchpadState

    /// GameController has no contact flag: (0,0) means lifted or an exact-centre hold.
    /// Both contacts use pad 0 with independent pointer IDs so the PC can track them.
    func forwardTouchpad(pad: GCExtendedGamepad, slot: UInt8) {
        guard let tp = touchpadElements(of: pad) else { return }
        forwardTouchpad(slot: slot, primary: (tp.primary.xAxis.value, tp.primary.yAxis.value),
                        secondary: (tp.secondary.xAxis.value, tp.secondary.yAxis.value), clicked: tp.button.isPressed)
    }

    func forwardTouchpad(slot: UInt8, primary: (x: Float, y: Float), secondary: (x: Float, y: Float),
                         clicked: Bool = false, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        guard quitChordDwellSlot != slot else { return }
        publishInputSnapshot()
        inputCore.forwardTouchpad(slot: slot, primary: primary, secondary: secondary, clicked: clicked, now: now)
    }

    func releaseControllerTouches(slot: UInt8? = nil) {
        inputCore.releaseControllerTouches(slot: slot)
    }
}
