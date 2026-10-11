// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Game mode preserves per-finger PC touch events; mouse mode uses the same snapshots as a trackpad.

import Foundation
import GameController

extension InputForwarder {

    // MARK: - Touchpad surface forwarding

    /// One tracked finger contact on a controller touchpad.
    struct TouchpadFinger {
        var active = false
        var pointerId: UInt32 = 0
        var x: Float = 0   // last sent, host-space [0,1]
        var y: Float = 0
    }

    /// Per-slot touchpad finger state (primary + secondary contact).
    struct TouchpadState {
        var primary = TouchpadFinger()
        var secondary = TouchpadFinger()
    }

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

extension InputCore {
    func forwardTouchpad(slot: UInt8, primary: (x: Float, y: Float), secondary: (x: Float, y: Float),
                         clicked: Bool = false, now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        guard snapshot.ready, snapshot.focused, snapshot.controllersAnnounced,
              !chordSlots.contains(slot) else { return }
        if controllerMouseStates[slot]?.isMouse == true {
            forwardTouchpadMouse(slot: slot, primary: primary, secondary: secondary, clicked: clicked, now: now)
            return
        }
        var state = touchpadStates[slot] ?? InputForwarder.TouchpadState()
        updateFinger(&state.primary, position: primary, slot: slot)
        updateFinger(&state.secondary, position: secondary, slot: slot)
        touchpadStates[slot] = state
    }

    func releaseControllerTouches(slot: UInt8? = nil) {
        lock.lock(); defer { lock.unlock() }
        for key in Array(touchpadStates.keys) where slot == nil || slot == key {
            guard var state = touchpadStates.removeValue(forKey: key), snapshot.ready else { continue }
            endFinger(&state.primary, slot: key)
            endFinger(&state.secondary, slot: key)
        }
    }

    private func updateFinger(_ finger: inout InputForwarder.TouchpadFinger,
                              position: (x: Float, y: Float), slot: UInt8) {
        let (rawX, rawY) = position
        let touching = rawX != 0 || rawY != 0
        // GameController: x ∈ [-1,1] left→right, y ∈ [-1,1] bottom→top.
        // Host touch space: [0,1] with a top-left origin, so flip Y.
        let nx = (rawX + 1) / 2
        let ny = (1 - rawY) / 2

        if touching, !finger.active {
            finger.active = true
            finger.pointerId = nextTouchPointerId
            nextTouchPointerId &+= 1
            if nextTouchPointerId == 0 { nextTouchPointerId = 1 }
            finger.x = nx; finger.y = ny
            let rc = backend?.sendControllerTouch(
                num: slot, eventType: UInt8(StreamProtocol.LI_TOUCH_EVENT_DOWN),
                touchpadIndex: 0, pointerId: finger.pointerId, x: nx, y: ny, pressure: 1.0) ?? -2
            record("LiSendControllerTouchEvent2(down)", rc)
        } else if touching, finger.active {
            if nx != finger.x || ny != finger.y {
                finger.x = nx; finger.y = ny
                let rc = backend?.sendControllerTouch(
                    num: slot, eventType: UInt8(StreamProtocol.LI_TOUCH_EVENT_MOVE),
                    touchpadIndex: 0, pointerId: finger.pointerId, x: nx, y: ny, pressure: 1.0) ?? -2
                record("LiSendControllerTouchEvent2(move)", rc)
            }
        } else if !touching, finger.active {
            endFinger(&finger, slot: slot)
        }
    }

    private func endFinger(_ finger: inout InputForwarder.TouchpadFinger, slot: UInt8) {
        guard finger.active else { return }
        finger.active = false
        let rc = backend?.sendControllerTouch(
            num: slot, eventType: UInt8(StreamProtocol.LI_TOUCH_EVENT_UP),
            touchpadIndex: 0, pointerId: finger.pointerId, x: finger.x, y: finger.y, pressure: 0) ?? -2
        record("LiSendControllerTouchEvent2(up)", rc)
    }
}
