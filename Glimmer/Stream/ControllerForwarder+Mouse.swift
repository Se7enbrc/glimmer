// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

@MainActor
struct ControllerMouseState {
    static let holdSeconds = 0.75
    var isMouse = false
    var buttons: Int32 = 0
    var analog = InputForwarder.neutralControllerAnalog
    var clicks: Set<Int32> = []
    var touchpad = ControllerTouchpadMouseState()
    private var startDownAt: TimeInterval?
    private var blocked = false

    init(isMouse: Bool = false) { self.isMouse = isMouse }

    // Moonlight toggles on release; another button or a stop chord spends the whole hold.
    mutating func update(buttons: Int32, analog: GamepadAnalog, chordHeld: Bool, now: TimeInterval) -> Bool {
        let start = StreamProtocol.PLAY_FLAG
        let wasDown = self.buttons & start != 0
        let isDown = buttons & start != 0
        if isDown && !wasDown { startDownAt = now; blocked = false }
        if chordHeld || buttons & ~start != 0 { blocked = true }
        let toggle = wasDown && !isDown && !blocked
            && startDownAt.map { now - $0 > Self.holdSeconds } == true
        if !isDown { startDownAt = nil }
        self.buttons = buttons
        self.analog = chordHeld ? InputForwarder.neutralControllerAnalog : analog
        if toggle { isMouse.toggle() }
        return toggle
    }
}

extension InputForwarder {
    // Positional clicks match moonlight-qt/app/streaming/input/gamepad.cpp.
    static let controllerMouseClicks: [(Int32, Int32)] = [
        (StreamProtocol.A_FLAG, StreamProtocol.BUTTON_LEFT),
        (StreamProtocol.B_FLAG, StreamProtocol.BUTTON_RIGHT),
        (StreamProtocol.X_FLAG, StreamProtocol.BUTTON_MIDDLE),
        (StreamProtocol.LB_FLAG, StreamProtocol.BUTTON_X1),
        (StreamProtocol.RB_FLAG, StreamProtocol.BUTTON_X2)
    ]
    static let controllerMouseClickFlags = controllerMouseClicks.reduce(Int32(0)) { $0 | $1.0 }

    @discardableResult
    func routeControllerMouse(slot: UInt8, buttons: Int32, analog: GamepadAnalog, chordHeld: Bool,
                              now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        guard forwardsControllerEvents else { return controllerMouseStates[slot]?.isMouse ?? false }
        var state = controllerMouseStates[slot] ?? ControllerMouseState()
        let previous = state.buttons
        let toggled = state.update(buttons: buttons, analog: analog, chordHeld: chordHeld, now: now)
        controllerMouseStates[slot] = state
        if toggled || chordHeld { updateControllerTouchpadMouse(slot: slot, state: ControllerTouchpadMouseState()) }
        let clicksChanged = (buttons ^ previous) & Self.controllerMouseClickFlags != 0
        // Surface-only frames must not allocate a button set on every touch sample.
        if (state.isMouse || !state.clicks.isEmpty) && (toggled || chordHeld || clicksChanged) {
            let clicks = state.isMouse && !chordHeld ? Set(Self.controllerMouseClicks.compactMap {
                buttons & $0.0 != 0 ? $0.1 : nil
            }) : []
            updateControllerMouseClicks(slot: slot, clicks: clicks)
        }
        if toggled {
            releaseControllerTouches(slot: slot)
            ControllerMotion.shared.setInputEnabled(!state.isMouse && forwardsControllerEvents, slot: slot)
            let rc = backend?.sendMultiController(num: Int16(slot), mask: Int16(bitPattern: gamepadMask),
                                                  buttons: 0, analog: Self.neutralControllerAnalog) ?? -2
            record("LiSendMultiControllerEvent(mouse toggle)", rc)
            Diag.info("controller \(slot): mouse mode \(state.isMouse ? "on" : "off")", "Controller")
            onControllerMouseChanged?(controllerMouseMessage(enabled: state.isMouse, slot: slot))
        }
        if state.isMouse && !chordHeld { sendControllerDpadScroll(buttons: buttons & ~previous) }
        updateControllerMousePolling()
        return state.isMouse
    }

    func controllerMouseMessage(enabled: Bool, slot: UInt8) -> String {
        let native = attachedControllers.values.first { $0.slot == slot }?.controller
        let hid = attachedHIDControllers.values.first { $0.slot == slot }?.device
        let name = gamepadMask.nonzeroBitCount > 1
            ? native?.vendorName ?? native?.productCategory ?? hid?.name ?? "Controller \(slot + 1)" : "Controller"
        return enabled ? "\(name) is now a mouse. Hold Menu to go back." : "\(name) is back in the game."
    }

    func sendControllerDpadScroll(buttons: Int32) {
        let vertical = (buttons & StreamProtocol.UP_FLAG != 0 ? 120 : 0)
            - (buttons & StreamProtocol.DOWN_FLAG != 0 ? 120 : 0)
        let horizontal = (buttons & StreamProtocol.RIGHT_FLAG != 0 ? 120 : 0)
            - (buttons & StreamProtocol.LEFT_FLAG != 0 ? 120 : 0)
        sendControllerScroll(x: Int16(horizontal), y: Int16(vertical))
    }

    func sendControllerScroll(x: Int16, y: Int16) {
        if y != 0 { record("LiSendHighResScrollEvent(controller)", backend?.sendScroll(y) ?? -2) }
        if x != 0 { record("LiSendHighResHScrollEvent(controller)", backend?.sendHScroll(x) ?? -2) }
    }

    @discardableResult
    func updateControllerMouseClicks(slot: UInt8, clicks: Set<Int32>) -> Bool {
        guard clicks != (controllerMouseStates[slot]?.clicks ?? []) else { return false }
        let before = controllerMouseButtons.union(heldMouseButtons)
        controllerMouseStates[slot]?.clicks = clicks
        sendMouseButtonEdges(before: before, after: controllerMouseButtons.union(heldMouseButtons))
        return true
    }

    var controllerMouseButtons: Set<Int32> {
        controllerMouseStates.values.reduce(into: Set<Int32>()) {
            $0.formUnion($1.clicks)
            if let button = $1.touchpad.clickedButton { $0.insert(button) }
        }
    }

    func sendMouseButtonEdges(before: Set<Int32>, after: Set<Int32>) {
        guard isReady else { return }
        for button in before.symmetricDifference(after).sorted() {
            let action = after.contains(button) ? StreamProtocol.BUTTON_ACTION_PRESS
                : StreamProtocol.BUTTON_ACTION_RELEASE
            record("LiSendMouseButtonEvent", backend?.sendMouseButton(action: Int8(action), button: button) ?? -2)
        }
    }

    func updatePhysicalMouseButton(_ button: Int32, pressed: Bool) {
        if pressed { heldMouseButtons.insert(button) } else { heldMouseButtons.remove(button) }
        // Keep every physical edge, including extra mouse buttons sharing a wire button.
        guard !controllerMouseButtons.contains(button), isReady else { return }
        let action = pressed ? StreamProtocol.BUTTON_ACTION_PRESS : StreamProtocol.BUTTON_ACTION_RELEASE
        record("LiSendMouseButtonEvent", backend?.sendMouseButton(action: Int8(action), button: button) ?? -2)
    }

    func updateControllerMousePolling() {
        guard controllerMouseStates.values.contains(where: { $0.isMouse }), forwardsControllerEvents else {
            controllerMouseTask?.cancel()
            controllerMouseTask = nil
            return
        }
        guard controllerMouseTask == nil else { return }
        controllerMouseTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled, let self else { return }
                self.pollControllerMouse()
            }
        }
    }

    // The cubic curve and 50 ms cadence follow Moonlight; right stick scroll is Glimmer's mapping.
    static func controllerMouseDelta(_ axis: Int16) -> Int16 {
        let scaled = Double(axis) / 32766 * 4
        let curved = scaled * scaled * scaled
        return abs(curved) > 2 ? Int16(curved - (curved > 0 ? 2 : -2)) : 0
    }

    func pollControllerMouse() {
        guard forwardsControllerEvents else { return }
        for state in controllerMouseStates.values where state.isMouse {
            let dx = Self.controllerMouseDelta(state.analog.leftStickX)
            let dy = -Self.controllerMouseDelta(state.analog.leftStickY)
            if dx != 0 || dy != 0 {
                record("LiSendMouseMoveEvent(controller)", backend?.sendMouseMove(dx: dx, dy: dy) ?? -2)
            }
            sendControllerScroll(x: Self.controllerMouseDelta(state.analog.rightStickX),
                                 y: Self.controllerMouseDelta(state.analog.rightStickY))
        }
    }

    func suspendControllerMouse() {
        for (slot, state) in controllerMouseStates {
            updateControllerTouchpadMouse(slot: slot, state: ControllerTouchpadMouseState())
            updateControllerMouseClicks(slot: slot, clicks: [])
            controllerMouseStates[slot] = ControllerMouseState(isMouse: state.isMouse)
        }
        controllerMouseTask?.cancel()
        controllerMouseTask = nil
    }

    func resetControllerMouse(slot: UInt8? = nil) {
        let slots = slot.map { [$0] } ?? Array(controllerMouseStates.keys)
        for slot in slots {
            updateControllerTouchpadMouse(slot: slot, state: ControllerTouchpadMouseState())
            updateControllerMouseClicks(slot: slot, clicks: [])
            controllerMouseStates[slot] = nil
        }
        updateControllerMousePolling()
    }
}
