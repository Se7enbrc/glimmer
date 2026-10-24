// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

/// Synchronous session input acceptance. Capture timestamps are monotonic system uptime.
/// The shell captures device state; the engine owns slots, mapping, release ordering and local chords.
public final class StreamInput: @unchecked Sendable {
    let lifecycleQueue = DispatchQueue(label: "io.ugfugl.Glimmer.inputLifecycle")
    let core = InputCore()
    let haptics = ControllerHaptics()
    let motion = ControllerMotion()
    let battery: ControllerBattery
    var registrations: [UInt8: RegistrationState] = [:]
    let chordDwell = ControllerChordDwell()
    var chordContext = UUID()
    var reconciliationScheduled = false
    @MainActor var reconciliationTimer: Timer?
    var terminal = false
    var focused = false
    let initialAttempt = UUID()
    var activeAttempt: UUID?
    var rearmOnActivation = false
    var holdActivation = false
    let emit: @Sendable (Event) -> Void

    struct RegistrationState {
        let identity: ControllerRegistration
        let descriptor: ControllerDescriptor
        let registeredAt: TimeInterval
        var acceptEventsAfter: TimeInterval = 0
        var rearm = ControllerRearmState()
        var announced = false
    }

    public enum Event: Sendable, Equatable {
        case controllersActive(Bool)
        case mouseMode(ControllerRegistration, enabled: Bool)
        case stopRequested
    }

    enum ControllerFeedback: Sendable {
        case rumble(lowFrequency: UInt16, highFrequency: UInt16)
        case triggerRumble(left: UInt16, right: UInt16)
        case rgbLED(red: UInt8, green: UInt8, blue: UInt8)
        case playerLEDs(solid: UInt8, flashing: UInt8)
        case motion(type: UInt8, reportRateHz: UInt16)
    }

    package init(battery: ControllerBattery = ControllerBattery(), emit: @escaping @Sendable (Event) -> Void) {
        self.battery = battery
        self.emit = emit
        core.onMotionInputEnabled = { [weak motion] slot, enabled in
            motion?.setInputEnabled(enabled, slot: slot)
        }
        core.onChord = { [weak self] slot, held, edge in self?.chordChanged(slot: slot, held: held, edge: edge) }
        core.onMouseMode = { [weak self] slot, enabled in
            guard let self, let registration = self.registrations[slot] else { return }
            self.emit(.mouseMode(registration.identity, enabled: enabled))
        }
    }

    convenience init(backend: any StreamingBackend, emit: @escaping @Sendable (Event) -> Void) {
        self.init(emit: emit)
        rebind(to: backend, attempt: initialAttempt)
    }

    /// Returns nil after stop or when all sixteen slots are occupied. Registration alone sends no input.
    public func registerController(_ descriptor: ControllerDescriptor) -> ControllerRegistration? {
        core.withLock {
            guard !terminal, let slot = core.reserveControllerSlot()
                else { return nil }
            let registration = ControllerRegistration(slot: slot, token: UUID())
            registrations[slot] = RegistrationState(identity: registration, descriptor: descriptor,
                registeredAt: ProcessInfo.processInfo.systemUptime)
            if descriptor.useNintendoLabels { core.snapshot.nintendoSlots.insert(slot) }
            if core.snapshot.ready { announce(registration) }
            scheduleReconciliation()
            return registration
        }
    }

    /// Binds prepared native actuators to this exact registration; callbacks never adopt a reused slot.
    public func attachFeedback(_ output: ControllerFeedbackOutput, to registration: ControllerRegistration) {
        core.withLock {
            guard !terminal, registrations[registration.slot]?.identity == registration else { return }
            haptics.register(slot: registration.slot, output: output)
        }
    }

    public func unregisterController(_ registration: ControllerRegistration) {
        core.withLock {
            guard registrations[registration.slot]?.identity == registration else { return }
            let slot = registration.slot
            let wasMouse = core.controllerMouseStates[slot]?.isMouse == true
            haptics.unregister(slot: slot)
            motion.unregister(slot: slot)
            Task { @MainActor [battery] in battery.unregister(slot: slot, token: registration.token) }
            core.releaseControllerTouches(slot: slot)
            core.resetControllerMouse(slot: slot)
            core.snapshot.mask &= ~(1 << slot)
            core.snapshot.nintendoSlots.remove(slot)
            core.retireController(slot: slot)
            core.current[slot] = nil
            core.updateChord(slot: slot, held: false, invalidate: true)
            registrations[slot] = nil
            if wasMouse { emit(.mouseMode(registration, enabled: false)) }
            scheduleReconciliation()
        }
    }

    public func submitController(_ registration: ControllerRegistration, sample: ControllerInputSample,
                                 capturedAt: TimeInterval) {
        InputTimingContext.begin(source: .controller, timestamp: capturedAt)
        defer { InputTimingContext.end() }
        core.withLock {
            defer { scheduleReconciliation() }
            guard !terminal, var state = registrations[registration.slot], state.identity == registration,
                  capturedAt.isFinite, capturedAt >= state.registeredAt, capturedAt >= state.acceptEventsAfter,
                  capturedAt >= core.snapshot.acceptEventsAfter else { return }
            let accepted = state.rearm.filter(buttons: sample.buttons.rawValue, analog: sample.analog,
                                              touch: sample.touchpad?.sanitized)
            registrations[registration.slot] = state
            if core.layouts != nil {
                core.rememberUnfocusedLayout(slot: registration.slot, physical: sample.physicalSample,
                    system: .init(buttons: sample.buttons.rawValue, analog: sample.analog, extras: sample.extraButtons))
            }
            guard accepts(capturedAt), ensureAnnounced(registration) else { return }
            core.receive(slot: registration.slot, buttons: accepted.buttons,
                         analog: accepted.analog, capturedAt: capturedAt, extras: sample.extraButtons,
                         physicalSample: sample.physicalSample)
            if let touch = accepted.touch {
                core.forwardTouchpad(slot: registration.slot, primary: (touch.primaryX, touch.primaryY),
                    secondary: (touch.secondaryX, touch.secondaryY), clicked: touch.clicked, now: capturedAt)
            }
            core.retainMouseTiming(slot: registration.slot)
        }
    }

    /// Closing focus releases local ownership. Reopening can suppress individually held controls until released.
    public func setFocused(_ value: Bool, suppressHeldControls: Bool = true) {
        core.withLock {
            guard !terminal, focused != value else { return }
            focused = value
            haptics.setOwnership(value)
            for slot in registrations.keys {
                motion.setInputEnabled(value && core.controllerMouseStates[slot]?.isMouse != true, slot: slot)
            }
            if !value { releaseOwnership() }
            if value && suppressHeldControls {
                for slot in registrations.keys {
                    registrations[slot]?.rearm.suppressHeld()
                }
            }
            core.snapshot.focused = value
            core.snapshot.acceptEventsAfter = ProcessInfo.processInfo.systemUptime
        }
    }

    func accepts(_ timestamp: TimeInterval) -> Bool {
        !terminal && core.snapshot.ready && core.snapshot.focused
            && timestamp.isFinite && timestamp >= core.snapshot.acceptEventsAfter
    }

    // Backend lifecycle enqueues under its latch; no core lock or backend call occurs inside that latch.
    func enqueueActivation(_ value: Bool) { enqueueActivation(value, attempt: initialAttempt) }

    func activate(_ value: Bool) { activate(value, attempt: initialAttempt) }

    func activate(_ value: Bool, attempt: UUID) {
        core.withLock {
            guard !terminal, activeAttempt == attempt, core.backend != nil else { return }
            if value && holdActivation { return }
            if value {
                if rearmOnActivation {
                    for slot in registrations.keys { registrations[slot]?.rearm.suppressHeld() }
                    rearmOnActivation = false
                }
                haptics.streamActivated(appActive: focused)
                haptics.setOwnership(focused)
                if let backend = core.backend { motion.streamActivated(backend: backend) }
            } else {
                haptics.stopAll(reason: "controllers deactivated")
                motion.stopAll(reason: "controllers deactivated")
                battery.pause()
            }
            if !value { releaseOwnership() }
            core.snapshot.ready = value
            core.snapshot.focused = focused
            core.snapshot.acceptEventsAfter = ProcessInfo.processInfo.systemUptime
            if value {
                for slot in registrations.keys { registrations[slot]?.announced = false }
                for state in registrations.values { announce(state.identity) }
            }
            scheduleReconciliation()
            emit(.controllersActive(value))
        }
    }

    func stop() {
        core.withLock {
            guard !terminal else { return }
            haptics.stopAll(reason: "connection stopped")
            motion.stopAll(reason: "connection stopped")
            battery.pause()
            activeAttempt = nil
            Task { @MainActor [self, battery] in
                battery.stopAll()
                reconcile()
            }
            for slot in registrations.keys { haptics.unregister(slot: slot); motion.unregister(slot: slot) }
            releaseOwnership()
            terminal = true
            core.snapshot.ready = false
            core.snapshot.focused = false
            core.backend = nil
            registrations.removeAll()
            emit(.controllersActive(false))
        }
    }

    func releaseOwnership() {
        invalidateChordContext()
        core.resetPointerMotion()
        core.releaseControllerTouches()
        core.suspendControllerMouse()
        core.heldMouseButtons.removeAll()
        core.clearChords()
        core.releases.releaseAll()
        core.flushReleases()
        core.resetScroll()
        scheduleReconciliation()
    }

    func announce(_ registration: ControllerRegistration) {
        guard !terminal, core.snapshot.ready, let state = registrations[registration.slot],
              state.identity == registration, core.flushReleases() else { return }
        let descriptor = state.descriptor
        let result = core.announceController(slot: registration.slot,
            arrival: ControllerArrival(type: descriptor.kind.rawValue,
                supportedButtons: UInt32(bitPattern: descriptor.supportedButtons.rawValue),
                caps: descriptor.capabilities.rawValue))
        if result == 0 {
            registrations[registration.slot]?.announced = true
            announceBattery(registration)
        }
    }

    func ensureAnnounced(_ registration: ControllerRegistration) -> Bool {
        if registrations[registration.slot]?.announced != true { announce(registration) }
        return registrations[registration.slot]?.announced == true
    }

    func feedback(slot: UInt16, _ value: ControllerFeedback) {
        feedback(slot: slot, value, attempt: initialAttempt)
    }

    func feedback(slot: UInt16, _ value: ControllerFeedback, attempt: UUID) {
        core.withLock {
            guard !terminal, activeAttempt == attempt, core.snapshot.ready, let slot = UInt8(exactly: slot),
                  registrations[slot] != nil else { return }
            switch value {
            case .rumble(let low, let high): haptics.setRumble(controllerNumber: UInt16(slot), lowFreq: low, highFreq: high)
            case .triggerRumble(let left, let right):
                haptics.setTriggerRumble(controllerNumber: UInt16(slot), left: left, right: right)
            case .rgbLED(let red, let green, let blue):
                haptics.setLight(controllerNumber: UInt16(slot), red: red, green: green, blue: blue)
            case .playerLEDs(let solid, let flashing):
                haptics.setPlayerLEDs(controllerNumber: UInt16(slot), solid: solid, flashing: flashing)
            case .motion(let type, let rate):
                motion.setMotionEventState(controllerNumber: UInt16(slot), motionType: type, reportRateHz: rate)
            }
        }
    }
}
