// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

struct ControllerTouchpadMouseState {
    struct Movement: Equatable {
        var dx: Int16 = 0
        var dy: Int16 = 0
        var scrollX: Int16 = 0
        var scrollY: Int16 = 0
    }

    private(set) var clickedButton: Int32?
    private var clickDown = false
    private var contacts: UInt8 = 0
    private var anchor = SIMD2<Float>.zero
    private var anchorTime: TimeInterval = 0
    private var residual = SIMD2<Float>.zero
    private var scroll = ScrollQuantizer()

    // GameController uses (0,0) for no contact, including the ambiguous exact centre.
    static func contact(_ position: (x: Float, y: Float)) -> SIMD2<Float>? {
        guard position.x.isFinite, position.y.isFinite, position.x != 0 || position.y != 0 else { return nil }
        return SIMD2((min(1, max(-1, position.x)) + 1) / 2,
                     (1 - min(1, max(-1, position.y))) / 2)
    }

    mutating func update(primary: SIMD2<Float>?, secondary: SIMD2<Float>?, clicked: Bool,
                         now: TimeInterval) -> Movement {
        let nextContacts: UInt8 = (primary == nil ? 0 : 1) | (secondary == nil ? 0 : 2)
        if clicked && !clickDown {
            clickedButton = nextContacts == 3 ? StreamProtocol.BUTTON_RIGHT : StreamProtocol.BUTTON_LEFT
        } else if !clicked {
            clickedButton = nil
        }
        clickDown = clicked
        let point = nextContacts == 3 ? ((primary ?? .zero) + (secondary ?? .zero)) / 2
            : primary ?? secondary ?? .zero
        // Rebase on every contact change so landing, lifting and changing gestures never move the pointer.
        guard nextContacts == contacts, nextContacts != 0 else {
            contacts = nextContacts
            anchor = point
            anchorTime = now
            residual = .zero
            scroll.reset()
            return Movement()
        }
        let delta = (point - anchor) * SIMD2<Float>(1, 1080.0 / 1920.0)
        let distance = (delta.x * delta.x + delta.y * delta.y).squareRoot()
        // Keep a fixed anchor inside the noise band; slow deliberate motion can still cross it.
        guard distance > 0.0008 else { return Movement() }
        let elapsed = Float(min(0.1, max(1.0 / 240, now - anchorTime)))
        anchor = point
        anchorTime = now
        let gain: Float = nextContacts == 3 ? 1200 : 900 * (1 + 0.35 * min(1, distance / elapsed))
        residual += delta * gain
        let dx = Int16(residual.x.rounded(.towardZero))
        let dy = Int16(residual.y.rounded(.towardZero))
        residual -= SIMD2(Float(dx), Float(dy))
        guard nextContacts == 3 else { return Movement(dx: dx, dy: dy) }
        // Natural scrolling moves the content with the fingers through the existing wheel quantizer.
        return Movement(scrollX: Int16(scroll.consumeHorizontal(-Int(dx), precise: true)),
                        scrollY: Int16(scroll.consumeVertical(-Int(dy), precise: true)))
    }
}

extension InputForwarder {
    func forwardTouchpadMouse(slot: UInt8, primary: (x: Float, y: Float), secondary: (x: Float, y: Float),
                              clicked: Bool, now: TimeInterval) {
        guard quitChordDwellSlot != slot, var state = controllerMouseStates[slot]?.touchpad else { return }
        let movement = state.update(primary: ControllerTouchpadMouseState.contact(primary),
                                    secondary: ControllerTouchpadMouseState.contact(secondary),
                                    clicked: clicked, now: now)
        updateControllerTouchpadMouse(slot: slot, state: state)
        if movement.dx != 0 || movement.dy != 0 {
            record("LiSendMouseMoveEvent(touchpad)", backend?.sendMouseMove(dx: movement.dx, dy: movement.dy) ?? -2)
        }
        sendControllerScroll(x: movement.scrollX, y: movement.scrollY)
    }

    func updateControllerTouchpadMouse(slot: UInt8, state: ControllerTouchpadMouseState) {
        guard controllerMouseStates[slot]?.touchpad.clickedButton != state.clickedButton else {
            controllerMouseStates[slot]?.touchpad = state
            return
        }
        let before = controllerMouseButtons.union(heldMouseButtons)
        controllerMouseStates[slot]?.touchpad = state
        sendMouseButtonEdges(before: before, after: controllerMouseButtons.union(heldMouseButtons))
    }
}
