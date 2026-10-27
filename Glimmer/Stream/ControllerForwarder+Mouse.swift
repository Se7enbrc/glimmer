// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import Foundation

extension InputForwarder {
    @discardableResult
    func routeControllerMouse(slot: UInt8, buttons: Int32, analog: GamepadAnalog, chordHeld: Bool,
                              now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        publishInputSnapshot()
        return inputCore.withLock {
            let wasMouse = inputCore.controllerMouseStates[slot]?.isMouse ?? false
            let isMouse = inputCore.routeControllerMouse(slot: slot, buttons: buttons, analog: analog,
                                                        chordHeld: chordHeld, now: now, notifyMode: false)
            inputCore.updateChord(slot: slot, held: chordHeld)
            if wasMouse != isMouse { controllerMouseModeChanged(slot: slot, enabled: isMouse) }
            return isMouse
        }
    }

    func controllerMouseModeChanged(slot: UInt8, enabled: Bool) {
        guard isReady, controllerMouseStates[slot]?.isMouse == enabled else { return }
        onControllerMouseChanged?(controllerMouseMessage(enabled: enabled, slot: slot))
    }

    func controllerMouseMessage(enabled: Bool, slot: UInt8) -> String {
        let native = attachedControllers.values.first { $0.slot == slot }?.controller
        let hid = attachedHIDControllers.values.first { $0.slot == slot }?.device
        let name = gamepadMask.nonzeroBitCount > 1
            ? native?.vendorName ?? native?.productCategory ?? hid?.name ?? "Controller \(slot + 1)" : "Controller"
        return ControllerMouseMapping.modeMessage(enabled: enabled, controller: name)
    }

    @discardableResult
    func updateControllerMouseClicks(slot: UInt8, clicks: Set<Int32>) -> Bool {
        inputCore.withLock { inputCore.updateControllerMouseClicks(slot: slot, clicks: clicks) }
    }

    var controllerMouseButtons: Set<Int32> { inputCore.withLock { inputCore.controllerMouseButtons } }

    func updatePhysicalMouseButton(_ button: Int32, pressed: Bool) {
        inputCore.withLock { inputCore.updatePhysicalMouseButton(button, pressed: pressed) }
    }

    func pollControllerMouse() { inputCore.pollControllerMouse() }
    func suspendControllerMouse() { inputCore.suspendControllerMouse() }
    func resetControllerMouse(slot: UInt8? = nil) { inputCore.resetControllerMouse(slot: slot) }
}
