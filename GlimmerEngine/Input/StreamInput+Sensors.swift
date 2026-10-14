// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

extension StreamInput {
    public func attachMotion(_ capture: ControllerMotionCapture, to registration: ControllerRegistration) {
        core.withLock {
            guard !terminal, registrations[registration.slot]?.identity == registration else { return }
            _ = motion.register(slot: registration.slot, capture: capture,
                                inputEnabled: focused && core.controllerMouseStates[registration.slot]?.isMouse != true)
        }
    }

    @MainActor
    public func attachBattery(_ capture: ControllerBatteryCapture, to registration: ControllerRegistration) {
        core.withLock {
            guard !terminal, registrations[registration.slot]?.identity == registration else { return }
            _ = battery.register(slot: registration.slot, capture: capture, token: registration.token)
            if core.snapshot.ready, registrations[registration.slot]?.announced == true {
                battery.announce(slot: registration.slot, backend: core.backend)
            }
        }
    }

    func announceBattery(_ registration: ControllerRegistration) {
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.core.withLock {
                guard !self.terminal, self.core.snapshot.ready,
                      self.registrations[registration.slot]?.identity == registration else { return }
                self.battery.announce(slot: registration.slot, backend: self.core.backend)
            }
        }
    }
}
