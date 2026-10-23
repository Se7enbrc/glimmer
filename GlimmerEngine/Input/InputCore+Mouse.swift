// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

package struct ControllerMouseState {
    package static let holdSeconds = 0.75
    package var isMouse = false
    package var buttons: Int32 = 0
    package var analog = InputCore.neutral
    package var clicks: Set<Int32> = []
    package var touchpad = ControllerTouchpadMouseState()
    #if os(iOS)
    package var pointerMotion = ControllerMouseMotion()
    package var scrollMotion = ControllerMouseMotion()
    package var sampledAt: TimeInterval?
    #endif
    private var startDownAt: TimeInterval?
    private var blocked = false

    package init(isMouse: Bool = false) { self.isMouse = isMouse }

    // Moonlight toggles on release; another button or a stop chord spends the whole hold.
    package mutating func update(buttons: Int32, analog: GamepadAnalog, chordHeld: Bool, now: TimeInterval) -> Bool {
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
    #if os(iOS)
    package static let controllerMousePollInterval = 1.0 / 120
    #else
    package static let controllerMousePollInterval = 0.05
    #endif

    // Positional clicks match moonlight-qt/app/streaming/input/gamepad.cpp.
    package static let controllerMouseClicks: [(Int32, Int32)] = [
        (StreamProtocol.A_FLAG, StreamProtocol.BUTTON_LEFT),
        (StreamProtocol.B_FLAG, StreamProtocol.BUTTON_RIGHT),
        (StreamProtocol.X_FLAG, StreamProtocol.BUTTON_MIDDLE),
        (StreamProtocol.LB_FLAG, StreamProtocol.BUTTON_X1),
        (StreamProtocol.RB_FLAG, StreamProtocol.BUTTON_X2)
    ]
    package static let controllerMouseClickFlags = controllerMouseClicks.reduce(Int32(0)) { $0 | $1.0 }

    @discardableResult
    package func routeControllerMouse(slot: UInt8, buttons: Int32, analog: GamepadAnalog, chordHeld: Bool,
                                      now: TimeInterval = ProcessInfo.processInfo.systemUptime,
                                      notifyMode: Bool = true) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard snapshot.ready, snapshot.focused else { return controllerMouseStates[slot]?.isMouse ?? false }
        var state = controllerMouseStates[slot] ?? ControllerMouseState()
        let previous = state.buttons
        let previousAnalog = state.analog
        let toggled = state.update(buttons: buttons, analog: analog, chordHeld: chordHeld, now: now)
        #if os(iOS)
        if state.isMouse || toggled {
            state.resetIdleMotion(rightPointer: controllerMouseMapping == .rightStick)
        }
        #endif
        controllerMouseStates[slot] = state
        if toggled || chordHeld {
            mouseTimings[slot] = nil
            updateControllerTouchpadMouse(slot: slot, state: ControllerTouchpadMouseState())
        }
        let clicksChanged = controllerMouseMapping.clicksChanged(
            buttons: buttons, previous: previous, analog: analog, oldAnalog: previousAnalog)
        // Surface-only frames must not allocate a button set on every touch sample.
        if (state.isMouse || !state.clicks.isEmpty) && (toggled || chordHeld || clicksChanged) {
            let clicks = state.isMouse && !chordHeld ? controllerMouseMapping.clicks(buttons: buttons, analog: analog) : []
            updateControllerMouseClicks(slot: slot, clicks: clicks)
        }
        if toggled {
            releaseControllerTouches(slot: slot)
            sendController(slot: slot, buttons: 0, analog: Self.neutral)
            Diag.info("controller \(slot): mouse mode \(state.isMouse ? "on" : "off")", "Controller")
            onMotionInputEnabled?(slot, !state.isMouse && snapshot.focused)
            if notifyMode { onMouseMode?(slot, state.isMouse) }
        }
        if state.isMouse && !chordHeld { sendControllerDpadScroll(buttons: buttons & ~previous) }
        updateControllerMousePolling()
        return state.isMouse
    }

    package func sendControllerDpadScroll(buttons: Int32) {
        let vertical = (buttons & StreamProtocol.UP_FLAG != 0 ? 120 : 0)
            - (buttons & StreamProtocol.DOWN_FLAG != 0 ? 120 : 0)
        let horizontal = (buttons & StreamProtocol.RIGHT_FLAG != 0 ? 120 : 0)
            - (buttons & StreamProtocol.LEFT_FLAG != 0 ? 120 : 0)
        sendControllerScroll(x: Int16(horizontal), y: Int16(vertical))
    }

    package func sendControllerScroll(x: Int16, y: Int16) {
        guard flushReleases() else { return }
        if y != 0 { record("LiSendHighResScrollEvent(controller)", backend?.sendScroll(y) ?? -2) }
        if x != 0 { record("LiSendHighResHScrollEvent(controller)", backend?.sendHScroll(x) ?? -2) }
    }

    @discardableResult
    package func updateControllerMouseClicks(slot: UInt8, clicks: Set<Int32>) -> Bool {
        guard clicks != (controllerMouseStates[slot]?.clicks ?? []) else { return false }
        let before = controllerMouseButtons.union(heldMouseButtons)
        controllerMouseStates[slot]?.clicks = clicks
        sendMouseButtonEdges(before: before, after: controllerMouseButtons.union(heldMouseButtons))
        return true
    }

    package var controllerMouseButtons: Set<Int32> {
        controllerMouseStates.values.reduce(into: Set<Int32>()) {
            $0.formUnion($1.clicks)
            if let button = $1.touchpad.clickedButton { $0.insert(button) }
        }
    }

    package func sendMouseButtonEdges(before: Set<Int32>, after: Set<Int32>) {
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

    package func updatePhysicalMouseButton(_ button: Int32, pressed: Bool) {
        if pressed { heldMouseButtons.insert(button) } else { heldMouseButtons.remove(button) }
        // Keep physical ownership distinct from clicks held by any controller.
        guard !controllerMouseButtons.contains(button) else { return }
        if pressed {
            sendMouseButtonEdges(before: [], after: [button])
        } else {
            sendMouseButtonEdges(before: [button], after: [])
        }
    }

    package func mouseNeedsUpdate(slot: UInt8, buttons: Int32, analog: GamepadAnalog) -> Bool {
        guard let state = controllerMouseStates[slot], state.isMouse else { return false }
        return state.buttons != buttons || state.analog != analog
    }

    package func updateControllerMousePolling() {
        let moving = controllerMouseStates.values.contains { $0.isMouse && Self.controllerMouseMoving($0.analog) }
        guard snapshot.ready, snapshot.focused, moving else {
            mousePollingGeneration &+= 1
            controllerMouseTimer?.cancel()
            controllerMouseTimer = nil
            return
        }
        guard controllerMouseTimer == nil else { return }
        mousePollingGeneration &+= 1
        let generation = mousePollingGeneration
        let timer = DispatchSource.makeTimerSource(queue: mouseQueue)
        timer.schedule(deadline: .now() + Self.controllerMousePollInterval,
                       repeating: Self.controllerMousePollInterval)
        timer.setEventHandler { [weak self] in self?.pollControllerMouse(generation: generation) }
        controllerMouseTimer = timer
        timer.resume()
    }

    package static func controllerMouseMoving(_ analog: GamepadAnalog) -> Bool {
        #if os(iOS)
        ControllerMouseMotion.velocity(x: analog.leftStickX, y: analog.leftStickY) != .zero
            || ControllerMouseMotion.velocity(x: analog.rightStickX, y: analog.rightStickY) != .zero
        #else
        controllerMouseDelta(analog.leftStickX) != 0 || controllerMouseDelta(analog.leftStickY) != 0
            || controllerMouseDelta(analog.rightStickX) != 0 || controllerMouseDelta(analog.rightStickY) != 0
        #endif
    }

    // The cubic curve and 50 ms cadence follow Moonlight; mapping selects which stick scrolls.
    package static func controllerMouseDelta(_ axis: Int16) -> Int16 {
        let scaled = Double(axis) / 32766 * 4
        let curved = scaled * scaled * scaled
        return abs(curved) > 2 ? Int16(curved - (curved > 0 ? 2 : -2)) : 0
    }

    package func pollControllerMouse(generation: UInt64? = nil,
                                     now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        guard generation == nil || generation == mousePollingGeneration else { return }
        guard snapshot.ready, snapshot.focused, snapshot.controllersAnnounced, flushReleases() else { return }
        // Updating sampled state must not copy a dictionary retained by its iterator on each tick.
        for slot in 0..<UInt8(Enet.maxGamepads) {
            guard let state = controllerMouseStates[slot], state.isMouse else { continue }
            if let timing = mouseTimings.removeValue(forKey: slot) {
                InputTimingContext.begin(samples: timing)
            }
            defer { InputTimingContext.end() }
            #if os(iOS)
            var sampled = state
            let delta = sampled.sampleMotion(rightPointer: controllerMouseMapping == .rightStick, now: now)
            controllerMouseStates[slot] = sampled
            if delta.pointer != .zero {
                record("LiSendMouseMoveEvent(controller)",
                       backend?.sendMouseMove(dx: delta.pointer.x, dy: -delta.pointer.y) ?? -2)
            }
            sendControllerScroll(x: delta.scroll.x, y: delta.scroll.y)
            #else
            let rightPointer = controllerMouseMapping == .rightStick
            let dx = Self.controllerMouseDelta(rightPointer ? state.analog.rightStickX : state.analog.leftStickX)
            let dy = -Self.controllerMouseDelta(rightPointer ? state.analog.rightStickY : state.analog.leftStickY)
            if dx != 0 || dy != 0 {
                record("LiSendMouseMoveEvent(controller)", backend?.sendMouseMove(dx: dx, dy: dy) ?? -2)
            }
            sendControllerScroll(
                x: Self.controllerMouseDelta(rightPointer ? state.analog.leftStickX : state.analog.rightStickX),
                y: Self.controllerMouseDelta(rightPointer ? state.analog.leftStickY : state.analog.rightStickY))
            #endif
        }
    }

    package func suspendControllerMouse() {
        lock.lock(); defer { lock.unlock() }
        mouseTimings.removeAll()
        for (slot, state) in controllerMouseStates {
            updateControllerTouchpadMouse(slot: slot, state: ControllerTouchpadMouseState())
            updateControllerMouseClicks(slot: slot, clicks: [])
            controllerMouseStates[slot] = ControllerMouseState(isMouse: state.isMouse)
        }
        mousePollingGeneration &+= 1
        controllerMouseTimer?.cancel()
        controllerMouseTimer = nil
    }

    package func resetControllerMouse(slot: UInt8? = nil) {
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
