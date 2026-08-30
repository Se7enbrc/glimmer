//
//  ControllerForwarder+Touchpad.swift
//
//  The DualSense / DualShock touchpad SURFACE: the per-finger contact state and
//  the down/move/up transitions forwarded to the host as controller touch
//  events. Split from ControllerForwarder.swift - same idiom as the
//  ControllerForwarder+QuitChord split, to keep that file under the length
//  limit. The touchpad *click* is not here: it rides the normal button bitmask
//  as TOUCHPAD_FLAG (ControllerForwarder+StatePush.swift). Per-slot finger state
//  lives on `InputForwarder` proper (`touchpadStates`, `nextTouchPointerId`) -
//  stored properties can't live in an extension - so the methods here rely on
//  default `internal` access to it.
//

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

    /// Translate the DualSense/DualShock touchpad surface into host touch
    /// events. GameController reports each finger as a `GCControllerDirectionPad`
    /// that reads (0,0) when no finger is present and the contact position
    /// otherwise; we derive down/move/up transitions from that. Both fingers
    /// ride touchpad index 0 (one physical pad, two contacts), each with its
    /// own pointerId so the host can track them independently.
    ///
    /// EXPERIMENTAL: GameController exposes no explicit "finger down" flag, so
    /// "touching" is inferred from a non-zero position. A finger resting at the
    /// exact geometric centre is therefore indistinguishable from "lifted" -
    /// acceptable for taps/swipes (which move), a known edge for a dead-centre
    /// hold. Validate on-device.
    func forwardTouchpad(pad: GCExtendedGamepad, slot: UInt8) {
        guard let tp = touchpadElements(of: pad) else { return }
        var state = touchpadStates[slot] ?? TouchpadState()
        updateFinger(&state.primary, dpad: tp.primary, slot: slot)
        updateFinger(&state.secondary, dpad: tp.secondary, slot: slot)
        touchpadStates[slot] = state
    }

    private func updateFinger(_ finger: inout TouchpadFinger, dpad: GCControllerDirectionPad, slot: UInt8) {
        let rawX = dpad.xAxis.value
        let rawY = dpad.yAxis.value
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
            finger.active = false
            let rc = backend?.sendControllerTouch(
                num: slot, eventType: UInt8(StreamProtocol.LI_TOUCH_EVENT_UP),
                touchpadIndex: 0, pointerId: finger.pointerId, x: finger.x, y: finger.y, pressure: 0.0) ?? -2
            record("LiSendControllerTouchEvent2(up)", rc)
        }
    }
}
