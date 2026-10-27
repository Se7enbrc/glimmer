// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GameController
import GlimmerEngine
import Synchronization

@MainActor
final class IOSControllerCapture {
    struct Calls {
        let register: (ControllerDescriptor) -> ControllerRegistration?
        let unregister: (ControllerRegistration) -> Void
        let submit: @Sendable (ControllerRegistration, ControllerInputSample, TimeInterval) -> Void
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
        let priorInputQueue: DispatchQueue?
        let priorHandler: GCExtendedGamepadValueChangedHandler?
        let gestures: [(GCControllerButtonInput, GCControllerElement.SystemGestureState)]
    }

    private final class Delivery: Sendable {
        let registrations = Mutex<[ControllerRegistration: UUID]>([:])
    }

    private let captureQueue = DispatchQueue(label: "io.ugfugl.Glimmer.controller-capture", qos: .userInteractive)
    private let delivery = Delivery()
    private let calls: Calls
    private let center: NotificationCenter
    private let readControllers: () -> [GCController]
    private let clock: () -> TimeInterval
    private var observations: [NSObjectProtocol] = []
    private var attached: [ObjectIdentifier: Attached] = [:]
    private var generation: UInt64 = 0
    private var focused = false
    private var focusRevision: UInt64 = 0
    private var stopped = false
    private var layouts: IOSControllerLayouts?
    private var layoutLoading: Task<Void, Never>?
    private var connectionChanged: (@MainActor (Bool) -> Void)?
    var beforeAttach: (() -> Void)?
    var refreshed: ((Bool) -> Void)?

    convenience init(input: StreamInput, scope: ControllerLayoutScope = .allGames) {
        self.init(calls: Calls(register: input.registerController, unregister: input.unregisterController,
                              submit: input.submitController, focus: { input.setFocused($0) },
                              feedback: { input.attachFeedback($1, to: $0) },
                              motion: { input.attachMotion($1, to: $0) },
                              battery: { input.attachBattery($1, to: $0) }))
        layouts = IOSControllerLayouts(input: input, scope: scope)
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
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect,
                     ControllerLayoutsModel.didChange] {
            observations.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, self.generation == attempt else { return }
                    if name == ControllerLayoutsModel.didChange { self.reloadLayouts() } else { self.refresh() }
                }
            })
        }
        refresh()
        if layouts != nil {
            layoutLoading = Task { [weak self] in
                await ControllerLayoutsModel.shared.load()
                guard !Task.isCancelled else { return }
                self?.reloadLayouts()
            }
        }
    }

    private func reloadLayouts() {
        guard !stopped else { return }
        let resume = focused
        if resume { setFocused(false) }
        for entry in attached.values { layouts?.configure(entry.controller, registration: entry.registration) }
        if resume { setFocused(true) }
    }

    func refresh() {
        guard !stopped, !observations.isEmpty else { return }
        let wasConnected = !attached.isEmpty
        let controllers = readControllers()
        let live = Set(controllers.map(ObjectIdentifier.init))
        for id in attached.keys where !live.contains(id) { detach(id) }
        for controller in controllers where attached[ObjectIdentifier(controller)] == nil { attach(controller) }
        refreshed?(!attached.isEmpty)
        if wasConnected != !attached.isEmpty { connectionChanged?(!attached.isEmpty) }
    }

    func observeConnections(_ changed: @escaping @MainActor (Bool) -> Void) {
        guard !stopped else { changed(false); return }
        connectionChanged = changed
        changed(!attached.isEmpty)
    }

    func setFocused(_ focused: Bool) {
        guard !stopped else { return }
        focusRevision &+= 1
        let revision = focusRevision
        guard self.focused != focused else { return }
        if focused {
            refresh()
            // A synchronous presence update can cancel this focus request during refresh.
            guard !stopped, focusRevision == revision else { return }
            // These are fresh reads while unfocused, so shared latches include controls held in the UI.
            for entry in attached.values {
                guard let pad = entry.controller.extendedGamepad else { continue }
                calls.submit(entry.registration, layouts?.sample(entry.controller) ?? Self.sample(pad), clock())
            }
            calls.focus(true)
            self.focused = true
            for entry in attached.values { install(entry) }
        } else {
            delivery.registrations.withLock { $0.removeAll() }
            calls.focus(false)
            self.focused = false
            for entry in attached.values { restore(entry) }
        }
    }

    func stop() {
        guard !stopped else { return }
        delivery.registrations.withLock { $0.removeAll() }
        calls.focus(false)
        focused = false
        stopped = true
        layoutLoading?.cancel()
        layoutLoading = nil
        generation &+= 1
        for observation in observations { center.removeObserver(observation) }
        observations.removeAll()
        for id in Array(attached.keys) { detach(id) }
        connectionChanged?(false)
        connectionChanged = nil
    }

    private func attach(_ controller: GCController) {
        guard let pad = controller.extendedGamepad else { return }
        beforeAttach?()
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
                             priorInputQueue: controller.input.unmapped?.queue, priorHandler: pad.valueChangedHandler,
                             gestures: buttons.map { ($0, $0.preferredSystemGestureState) })
        attached[ObjectIdentifier(controller)] = entry
        layouts?.configure(controller, registration: registration)
        if focused {
            // A newly attached pad may hold controls without delivering another native change.
            calls.submit(registration, layouts?.sample(controller) ?? Self.sample(pad), clock())
            install(entry)
        }
    }

    private func install(_ entry: Attached) {
        for (button, _) in entry.gestures { button.preferredSystemGestureState = .disabled }
        let registration = entry.registration
        let epoch = UUID()
        let submit = calls.submit
        delivery.registrations.withLock { $0[registration] = epoch }
        if let layout = layouts?.entry(entry.controller) {
            let reader = layout.reader
            let mapsGameInput = layout.mapsGameInput
            ControllerStreamHandlers.install(controller: entry.controller, input: reader.input, queue: captureQueue,
                mapsGameInput: mapsGameInput, shortcutElements: layout.shortcutElements,
                read: reader.sample) { @Sendable [delivery] sample, now in
                    delivery.registrations.withLock { registrations in
                        guard registrations[registration] == epoch else { return }
                        submit(registration, reader.streamSample(sample, mapsGameInput: mapsGameInput), now)
                    }
                }
            return
        }
        entry.controller.extendedGamepad?.valueChangedHandler = nil
        entry.controller.handlerQueue = captureQueue
        entry.controller.extendedGamepad?.valueChangedHandler = { @Sendable [delivery] pad, _ in
            // Hold validity through submission so focus loss and detach finish after any in-flight sample.
            delivery.registrations.withLock { registrations in
                guard registrations[registration] == epoch else { return }
                submit(registration, Self.sample(pad), pad.lastEventTimestamp)
            }
        }
    }

    private func restore(_ entry: Attached) {
        _ = delivery.registrations.withLock { $0.removeValue(forKey: entry.registration) }
        entry.controller.extendedGamepad?.valueChangedHandler = nil
        entry.controller.input.unmapped?.elementValueDidChangeHandler = nil
        entry.controller.input.unmapped?.queue = entry.priorInputQueue
        entry.controller.handlerQueue = entry.priorQueue
        entry.controller.extendedGamepad?.valueChangedHandler = entry.priorHandler
        for (button, state) in entry.gestures { button.preferredSystemGestureState = state }
    }

    private func detach(_ id: ObjectIdentifier) {
        guard let entry = attached.removeValue(forKey: id) else { return }
        restore(entry)
        layouts?.remove(entry.controller)
        calls.unregister(entry.registration)
        entry.feedback.invalidate()
        entry.motion.invalidate()
    }
}
