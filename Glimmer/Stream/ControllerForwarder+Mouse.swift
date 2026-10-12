// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import Foundation

struct ControllerMouseState {
    static let holdSeconds = 0.75
    var isMouse = false
    var buttons: Int32 = 0
    var analog = InputCore.neutral
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
        self.analog = chordHeld ? InputCore.neutral : analog
        if toggle { isMouse.toggle() }
        return toggle
    }
}

extension InputCore {
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
                              now: TimeInterval = ProcessInfo.processInfo.systemUptime,
                              notifyMode: Bool = true) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard snapshot.ready, snapshot.focused else { return controllerMouseStates[slot]?.isMouse ?? false }
        var state = controllerMouseStates[slot] ?? ControllerMouseState()
        let previous = state.buttons
        let toggled = state.update(buttons: buttons, analog: analog, chordHeld: chordHeld, now: now)
        controllerMouseStates[slot] = state
        if toggled || chordHeld {
            mouseTimings[slot] = nil
            updateControllerTouchpadMouse(slot: slot, state: ControllerTouchpadMouseState())
        }
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
            sendController(slot: slot, buttons: 0, analog: Self.neutral)
            Diag.info("controller \(slot): mouse mode \(state.isMouse ? "on" : "off")", "Controller")
            ControllerMotion.shared.setInputEnabled(!state.isMouse && snapshot.focused, slot: slot)
            if notifyMode { onMouseMode?(slot, state.isMouse) }
        }
        if state.isMouse && !chordHeld { sendControllerDpadScroll(buttons: buttons & ~previous) }
        updateControllerMousePolling()
        return state.isMouse
    }

    func sendControllerDpadScroll(buttons: Int32) {
        let vertical = (buttons & StreamProtocol.UP_FLAG != 0 ? 120 : 0)
            - (buttons & StreamProtocol.DOWN_FLAG != 0 ? 120 : 0)
        let horizontal = (buttons & StreamProtocol.RIGHT_FLAG != 0 ? 120 : 0)
            - (buttons & StreamProtocol.LEFT_FLAG != 0 ? 120 : 0)
        sendControllerScroll(x: Int16(horizontal), y: Int16(vertical))
    }

    func sendControllerScroll(x: Int16, y: Int16) {
        guard flushReleases() else { return }
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
        for button in before.symmetricDifference(after).sorted() {
            if after.contains(button) {
                guard snapshot.ready, flushReleases() else { continue }
                releases.hold(.mouse(button))
                record("LiSendMouseButtonEvent", backend?.sendMouseButton(
                    action: Int8(StreamProtocol.BUTTON_ACTION_PRESS), button: button) ?? -2)
            } else {
                InputTimingContext.allowRelease(.mouse(button))
                releases.release(.mouse(button))
                flushReleases()
            }
        }
    }

    func updatePhysicalMouseButton(_ button: Int32, pressed: Bool) {
        if pressed { heldMouseButtons.insert(button) } else { heldMouseButtons.remove(button) }
        // Keep physical ownership distinct from clicks held by any controller.
        guard !controllerMouseButtons.contains(button) else { return }
        if pressed {
            sendMouseButtonEdges(before: [], after: [button])
        } else {
            sendMouseButtonEdges(before: [button], after: [])
        }
    }

    func mouseNeedsUpdate(slot: UInt8, buttons: Int32, analog: GamepadAnalog) -> Bool {
        guard let state = controllerMouseStates[slot], state.isMouse else { return false }
        return state.buttons != buttons || state.analog != analog
    }

    func updateControllerMousePolling() {
        let moving = controllerMouseStates.values.contains { state in
            state.isMouse && (Self.controllerMouseDelta(state.analog.leftStickX) != 0
                || Self.controllerMouseDelta(state.analog.leftStickY) != 0
                || Self.controllerMouseDelta(state.analog.rightStickX) != 0
                || Self.controllerMouseDelta(state.analog.rightStickY) != 0)
        }
        guard snapshot.ready, snapshot.focused, moving else {
            controllerMouseTimer?.cancel()
            controllerMouseTimer = nil
            return
        }
        guard controllerMouseTimer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: mouseQueue)
        timer.schedule(deadline: .now() + .milliseconds(50), repeating: .milliseconds(50))
        timer.setEventHandler { [weak self] in self?.pollControllerMouse() }
        controllerMouseTimer = timer
        timer.resume()
    }

    // The cubic curve and 50 ms cadence follow Moonlight; right stick scroll is Glimmer's mapping.
    static func controllerMouseDelta(_ axis: Int16) -> Int16 {
        let scaled = Double(axis) / 32766 * 4
        let curved = scaled * scaled * scaled
        return abs(curved) > 2 ? Int16(curved - (curved > 0 ? 2 : -2)) : 0
    }

    func pollControllerMouse() {
        lock.lock(); defer { lock.unlock() }
        guard snapshot.ready, snapshot.focused, snapshot.controllersAnnounced, flushReleases() else { return }
        for (slot, state) in controllerMouseStates where state.isMouse {
            if let timing = mouseTimings.removeValue(forKey: slot) {
                InputTimingContext.begin(samples: timing)
            }
            defer { InputTimingContext.end() }
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
        lock.lock(); defer { lock.unlock() }
        mouseTimings.removeAll()
        for (slot, state) in controllerMouseStates {
            updateControllerTouchpadMouse(slot: slot, state: ControllerTouchpadMouseState())
            updateControllerMouseClicks(slot: slot, clicks: [])
            controllerMouseStates[slot] = ControllerMouseState(isMouse: state.isMouse)
        }
        controllerMouseTimer?.cancel()
        controllerMouseTimer = nil
    }

    func resetControllerMouse(slot: UInt8? = nil) {
        lock.lock(); defer { lock.unlock() }
        let slots = slot.map { [$0] } ?? Array(controllerMouseStates.keys)
        for slot in slots {
            updateControllerTouchpadMouse(slot: slot, state: ControllerTouchpadMouseState())
            updateControllerMouseClicks(slot: slot, clicks: [])
            controllerMouseStates[slot] = nil
            mouseTimings[slot] = nil
        }
        updateControllerMousePolling()
    }
}

extension InputForwarder {
    @discardableResult
    func routeControllerMouse(slot: UInt8, buttons: Int32, analog: GamepadAnalog, chordHeld: Bool,
                              now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
        publishInputSnapshot()
        return inputCore.withLock {
            let wasMouse = inputCore.controllerMouseStates[slot]?.isMouse ?? false
            let isMouse = inputCore.routeControllerMouse(slot: slot, buttons: buttons, analog: analog,
                                                        chordHeld: chordHeld, now: now, notifyMode: false)
            if chordHeld { inputCore.chordSlots.insert(slot) } else { inputCore.chordSlots.remove(slot) }
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
        return enabled ? "\(name) is now a mouse. Hold Menu to go back." : "\(name) is back in the game."
    }

    @discardableResult
    func updateControllerMouseClicks(slot: UInt8, clicks: Set<Int32>) -> Bool {
        inputCore.withLock { inputCore.updateControllerMouseClicks(slot: slot, clicks: clicks) }
    }

    var controllerMouseButtons: Set<Int32> { inputCore.withLock { inputCore.controllerMouseButtons } }

    func updatePhysicalMouseButton(_ button: Int32, pressed: Bool) {
        inputCore.withLock { inputCore.updatePhysicalMouseButton(button, pressed: pressed) }
    }

    static func controllerMouseDelta(_ axis: Int16) -> Int16 { InputCore.controllerMouseDelta(axis) }
    func pollControllerMouse() { inputCore.pollControllerMouse() }
    func suspendControllerMouse() { inputCore.suspendControllerMouse() }
    func resetControllerMouse(slot: UInt8? = nil) { inputCore.resetControllerMouse(slot: slot) }
}
