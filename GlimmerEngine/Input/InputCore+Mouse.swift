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
    package var clickMask: UInt8 = 0
    package var extras = SIMD2<UInt64>.zero
    package var pointerMotion = ControllerMouseMotion()
    package var scrollMotion = ControllerMouseMotion()
    package var sampledAt: TimeInterval?
    private var scrollNotches = ScrollQuantizer()
    private var startDownAt: TimeInterval?
    private var blocked = false
    private var holdComplete = false

    package init(isMouse: Bool = false) { self.isMouse = isMouse }

    @inline(__always)
    package func isMoving(_ sticks: @autoclosure () -> (pointer: SIMD2<Int16>, scroll: SIMD2<Int16>)) -> Bool {
        guard isMouse else { return false }
        let sticks = sticks()
        return ControllerMouseMotion.velocity(sticks.pointer) != .zero || ControllerMouseMotion.velocity(sticks.scroll) != .zero
    }

    // Idle sticks drop their residual so a new deflection never starts with a stale step.
    package mutating func resetIdleMotion(_ sticks: (pointer: SIMD2<Int16>, scroll: SIMD2<Int16>)) {
        let pointerIdle = !isMouse || ControllerMouseMotion.velocity(sticks.pointer) == .zero
        let scrollIdle = !isMouse || ControllerMouseMotion.velocity(sticks.scroll) == .zero
        if pointerIdle { pointerMotion = ControllerMouseMotion() }
        if scrollIdle { scrollMotion = ControllerMouseMotion(); scrollNotches.reset() }
        if pointerIdle && scrollIdle { sampledAt = nil }
    }

    package mutating func sampleMotion(_ sticks: (pointer: SIMD2<Int16>, scroll: SIMD2<Int16>), now: TimeInterval)
        -> (pointer: SIMD2<Int16>, scroll: SIMD2<Int16>) {
        let seconds = sampledAt.map { now - $0 } ?? InputCore.controllerMousePollInterval
        sampledAt = now
        let scroll = scrollMotion.step(sticks.scroll, seconds: seconds)
        // Games count wheel messages, so a stick scrolls in whole notches like a wheel.
        let notches = SIMD2(Int16(clamping: scrollNotches.consumeHorizontal(Int(scroll.x), precise: true)),
                            Int16(clamping: scrollNotches.consumeVertical(Int(scroll.y), precise: true)))
        return (pointerMotion.step(sticks.pointer, seconds: seconds), notches)
    }

    // A hold changes modes only on release; another button or a system chord spends the hold.
    package mutating func update(buttons: Int32, analog: GamepadAnalog, chordHeld: Bool,
                                 now: TimeInterval, toggleOnHold: Bool = true,
                                 toggleChord: ControllerPhysicalChord = ControllerMousePlan().toggle,
                                 extras: SIMD2<UInt64> = .zero) -> Bool {
        let sample = ControllerMappingSample(buttons: buttons, analog: analog, extras: extras)
        let wasDown = startDownAt != nil
        let isDown = toggleChord.held(in: sample)
        if isDown && !wasDown { startDownAt = now; blocked = false; holdComplete = false }
        let otherButtons = sample.buttons & ~toggleChord.buttons != 0 || sample.extras & ~toggleChord.extras != .zero
        let otherTriggers = (sample.analog[0] >= 128 && toggleChord.triggers & 1 == 0)
            || (sample.analog[1] >= 128 && toggleChord.triggers & 2 == 0)
        if chordHeld || otherButtons || otherTriggers { blocked = true }
        if startDownAt.map({ now - $0 > Self.holdSeconds }) == true { holdComplete = true }
        if !isDown && !holdComplete { blocked = true }
        let released = toggleChord.released(in: sample)
        let toggle = wasDown && released && !blocked
            && holdComplete
        if released { startDownAt = nil }
        self.buttons = buttons
        self.extras = extras
        self.analog = chordHeld ? InputCore.neutral : analog
        if toggle && toggleOnHold { isMouse.toggle() }
        return toggle
    }
}

extension InputCore {
    // Velocity steps at display rate; a 50 ms cadence reads as a 20 Hz pointer.
    package static let controllerMousePollInterval = 1.0 / 120

    package func mousePlan(slot: UInt8) -> ControllerMousePlan {
        layouts?.states[Int(slot)]?.mouse ?? controllerMousePlan
    }

    @discardableResult
    package func routeControllerMouse(slot: UInt8, buttons: Int32, analog: GamepadAnalog, chordHeld: Bool,
                                      now: TimeInterval = ProcessInfo.processInfo.systemUptime,
                                      notifyMode: Bool = true, extras: SIMD2<UInt64> = .zero) -> Bool {
        lock.lock(); defer { lock.unlock() }
        guard snapshot.ready, snapshot.focused else { return controllerMouseStates[slot]?.isMouse ?? false }
        var state = controllerMouseStates[slot] ?? ControllerMouseState()
        let plan = mousePlan(slot: slot)
        let opensControls = controllerMenuOpensControls && notifyMode
        let toggled = state.update(buttons: buttons, analog: analog, chordHeld: chordHeld, now: now,
                                   toggleOnHold: !opensControls, toggleChord: plan.toggle, extras: extras)
        if toggled && opensControls {
            controllerMouseStates[slot] = state
            onControllerMenu?(slot)
            return state.isMouse
        }
        if state.isMouse || toggled { state.resetIdleMotion(plan.sticks(state.analog)) }
        controllerMouseStates[slot] = state
        if toggled || chordHeld {
            mouseTimings[slot] = nil
            updateControllerTouchpadMouse(slot: slot, state: ControllerTouchpadMouseState())
        }
        let mask = state.isMouse && !chordHeld
            ? plan.clickMask(.init(buttons: buttons, analog: analog, extras: extras)) : 0
        // Allocate click ownership only when an edge changes, never for stick or surface samples.
        if mask != state.clickMask {
            controllerMouseStates[slot]?.clickMask = mask
            updateControllerMouseClicks(slot: slot, clicks: plan.clicks(mask))
        }
        if toggled {
            releaseControllerTouches(slot: slot)
            sendController(slot: slot, buttons: 0, analog: Self.neutral)
            Diag.info("controller \(slot): mouse mode \(state.isMouse ? "on" : "off")", "Controller")
            onMotionInputEnabled?(slot, !state.isMouse && snapshot.focused)
            if notifyMode { onMouseMode?(slot, state.isMouse) }
        }
        updateControllerMousePolling()
        return state.isMouse
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
        let moving = controllerMouseStates.contains { slot, state in
            state.isMoving(mousePlan(slot: slot).sticks(state.analog))
        }
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
        ControllerMouseMotion.velocity(SIMD2(analog.leftStickX, analog.leftStickY)) != .zero
            || ControllerMouseMotion.velocity(SIMD2(analog.rightStickX, analog.rightStickY)) != .zero
    }

    package func pollControllerMouse(generation: UInt64? = nil,
                                     now: TimeInterval = ProcessInfo.processInfo.systemUptime) {
        lock.lock(); defer { lock.unlock() }
        guard generation == nil || generation == mousePollingGeneration else { return }
        guard snapshot.ready, snapshot.focused, snapshot.controllersAnnounced, flushReleases() else { return }
        // Updating sampled state must not copy a dictionary retained by its iterator on each tick.
        for slot in 0..<UInt8(Enet.maxGamepads) {
            guard var state = controllerMouseStates[slot], state.isMouse else { continue }
            if let timing = mouseTimings.removeValue(forKey: slot) {
                InputTimingContext.begin(samples: timing)
            }
            defer { InputTimingContext.end() }
            let delta = state.sampleMotion(mousePlan(slot: slot).sticks(state.analog), now: now)
            controllerMouseStates[slot] = state
            if delta.pointer != .zero {
                record("LiSendMouseMoveEvent(controller)",
                       backend?.sendMouseMove(dx: delta.pointer.x, dy: -delta.pointer.y) ?? -2)
            }
            sendControllerScroll(x: delta.scroll.x, y: delta.scroll.y)
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
