// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GameController
import GlimmerEngine

@MainActor
final class IOSControllerCapture {
    struct Calls {
        let register: (ControllerDescriptor) -> ControllerRegistration?
        let unregister: (ControllerRegistration) -> Void
        let submit: (ControllerRegistration, ControllerInputSample, TimeInterval) -> Void
        let focus: (Bool) -> Void
        var feedback: ((ControllerRegistration, ControllerFeedbackOutput) -> Void)?
        var motion: ((ControllerRegistration, ControllerMotionCapture) -> Void)?
        var battery: ((ControllerRegistration, ControllerBatteryCapture) -> Void)?
    }

    private struct Attached {
        let controller: GCController
        let registration: ControllerRegistration
        let feedback: IOSControllerFeedback
        let motion: IOSControllerMotion
        let priorQueue: DispatchQueue
        let priorHandler: GCExtendedGamepadValueChangedHandler?
        let gestures: [(GCControllerButtonInput, GCControllerElement.SystemGestureState)]
    }

    private let calls: Calls
    private let center: NotificationCenter
    private let readControllers: () -> [GCController]
    private let clock: () -> TimeInterval
    private var observations: [NSObjectProtocol] = []
    private var attached: [ObjectIdentifier: Attached] = [:]
    private var generation: UInt64 = 0
    private var focused = false
    private var stopped = false

    convenience init(input: StreamInput) {
        self.init(calls: Calls(register: input.registerController, unregister: input.unregisterController,
                              submit: input.submitController, focus: { input.setFocused($0) },
                              feedback: { input.attachFeedback($1, to: $0) },
                              motion: { input.attachMotion($1, to: $0) },
                              battery: { input.attachBattery($1, to: $0) }))
    }

    init(calls: Calls, center: NotificationCenter = .default,
         readControllers: @escaping () -> [GCController] = { GCController.controllers() },
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.calls = calls
        self.center = center
        self.readControllers = readControllers
        self.clock = clock
    }

    isolated deinit { stop() }

    func start() {
        guard !stopped, observations.isEmpty else { return }
        generation &+= 1
        let attempt = generation
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observations.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.generation == attempt else { return }
                    self.refresh()
                }
            })
        }
        refresh()
    }

    func refresh() {
        guard !stopped, !observations.isEmpty else { return }
        let controllers = readControllers()
        let live = Set(controllers.map(ObjectIdentifier.init))
        for id in attached.keys where !live.contains(id) { detach(id) }
        for controller in controllers where attached[ObjectIdentifier(controller)] == nil { attach(controller) }
    }

    func setFocused(_ focused: Bool) {
        guard !stopped, self.focused != focused else { return }
        if focused {
            refresh()
            // These are fresh reads while unfocused, so shared latches include controls held in the UI.
            for entry in attached.values {
                guard let pad = entry.controller.extendedGamepad else { continue }
                calls.submit(entry.registration, Self.sample(pad), clock())
            }
            calls.focus(true)
            self.focused = true
            for entry in attached.values { install(entry) }
        } else {
            calls.focus(false)
            self.focused = false
            for entry in attached.values { restore(entry) }
        }
    }

    func stop() {
        guard !stopped else { return }
        calls.focus(false)
        focused = false
        stopped = true
        generation &+= 1
        for observation in observations { center.removeObserver(observation) }
        observations.removeAll()
        for id in Array(attached.keys) { detach(id) }
    }

    private func attach(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        let nativeFeedback = IOSControllerFeedback(controller)
        let feedback = nativeFeedback.output()
        let nativeMotion = IOSControllerMotion(controller.motion)
        let motion = nativeMotion.output()
        let battery = IOSControllerBattery.capture(controller)
        var descriptor = Self.descriptor(controller, pad: pad)
        if calls.feedback != nil { descriptor.capabilities.formUnion(feedback.capabilities) }
        if calls.motion != nil { descriptor.capabilities.formUnion(motion.capabilities) }
        if calls.battery != nil, let battery { descriptor.capabilities.formUnion(battery.capabilities) }
        guard let registration = calls.register(descriptor) else { return }
        calls.feedback?(registration, feedback)
        calls.motion?(registration, motion)
        if let battery { calls.battery?(registration, battery) }
        let buttons = [pad.buttonOptions, pad.buttonMenu, pad.buttonHome].compactMap { $0 }
        let entry = Attached(controller: controller, registration: registration,
                             feedback: nativeFeedback, motion: nativeMotion, priorQueue: controller.handlerQueue,
                             priorHandler: pad.valueChangedHandler,
                             gestures: buttons.map { ($0, $0.preferredSystemGestureState) })
        attached[ObjectIdentifier(controller)] = entry
        if focused {
            install(entry)
            // A newly attached pad may hold controls without delivering another native change.
            calls.submit(registration, Self.sample(pad), clock())
        }
    }

    private func install(_ entry: Attached) {
        let id = ObjectIdentifier(entry.controller)
        let registration = entry.registration
        let attempt = generation
        entry.controller.handlerQueue = .main
        for (button, _) in entry.gestures { button.preferredSystemGestureState = .disabled }
        entry.controller.extendedGamepad?.valueChangedHandler = { [weak self] pad, _ in
            MainActor.assumeIsolated {
                guard let self, self.focused, !self.stopped, self.generation == attempt,
                      self.attached[id]?.registration == registration else { return }
                self.calls.submit(registration, Self.sample(pad), pad.lastEventTimestamp)
            }
        }
    }

    private func restore(_ entry: Attached) {
        entry.controller.extendedGamepad?.valueChangedHandler = entry.priorHandler
        entry.controller.handlerQueue = entry.priorQueue
        for (button, state) in entry.gestures { button.preferredSystemGestureState = state }
    }

    private func detach(_ id: ObjectIdentifier) {
        guard let entry = attached.removeValue(forKey: id) else { return }
        restore(entry)
        calls.unregister(entry.registration)
        entry.feedback.invalidate()
        entry.motion.invalidate()
    }
}
