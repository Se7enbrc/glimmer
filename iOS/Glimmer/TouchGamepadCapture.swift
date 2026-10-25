// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import UIKit

@MainActor
final class TouchGamepadCapture {
    struct Calls {
        let register: (ControllerDescriptor) -> ControllerRegistration?
        let unregister: (ControllerRegistration) -> Void
        let submit: (ControllerRegistration, ControllerInputSample, TimeInterval) -> Void
    }
    private let calls: Calls
    private var state = TouchGamepadState()
    private(set) var registration: ControllerRegistration?
    private(set) var enabled = false
    var invalidated: (() -> Void)?

    convenience init(input: StreamInput) {
        self.init(calls: Calls(register: input.registerController, unregister: input.unregisterController,
                              submit: input.submitController))
    }

    init(calls: Calls) { self.calls = calls }

    isolated deinit { detach() }

    @discardableResult func attach() -> Bool {
        if registration == nil { registration = calls.register(TouchElement.descriptor) }
        return registration != nil
    }

    func setEnabled(_ value: Bool) {
        guard enabled != value else { return }
        enabled = value && registration != nil
        if !enabled { cancel() }
        if enabled, let registration {
            // A fresh touch lease starts neutral, clearing the engine's held-control latch after focus resumes.
            calls.submit(registration, state.sample, ProcessInfo.processInfo.systemUptime)
        }
        invalidated?()
    }

    func cancel() {
        let sample = state.sample
        let held = !sample.buttons.isEmpty || sample.leftTrigger != 0 || sample.rightTrigger != 0
            || sample.leftStickX != 0 || sample.leftStickY != 0 || sample.rightStickX != 0 || sample.rightStickY != 0
        state.reset()
        if held, let registration {
            calls.submit(registration, state.sample, ProcessInfo.processInfo.systemUptime)
        }
        invalidated?()
    }

    func detach() {
        enabled = false
        state.reset()
        if let registration {
            self.registration = nil
            calls.unregister(registration)
        }
        invalidated?()
    }

    func begin(_ element: TouchElement) -> TouchGamepadState.Contact? {
        guard enabled else { return nil }
        return state.begin(element)
    }

    func update(_ contact: TouchGamepadState.Contact, value: CGPoint, at timestamp: TimeInterval) {
        guard enabled, let registration, timestamp.isFinite, state.update(contact, value: value) else { return }
        calls.submit(registration, state.sample, timestamp)
    }

    func end(_ contact: TouchGamepadState.Contact, at timestamp: TimeInterval) {
        guard enabled, let registration, timestamp.isFinite, state.end(contact) else { return }
        calls.submit(registration, state.sample, timestamp)
    }
}
