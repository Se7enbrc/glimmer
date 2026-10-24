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
        let announcement: ControllerBattery.Announcement? = core.withLock {
            guard !terminal, registrations[registration.slot]?.identity == registration else { return nil }
            _ = battery.register(slot: registration.slot, capture: capture, token: registration.token)
            if core.snapshot.ready, registrations[registration.slot]?.announced == true {
                return battery.prepareAnnouncement(slot: registration.slot, backend: core.backend)
            }
            return nil
        }
        if let announcement { battery.report(announcement) }
    }

    func announceBattery(_ registration: ControllerRegistration) {
        let attempt = activeAttempt
        Task { @MainActor [weak self] in
            guard let self else { return }
            let announcement: ControllerBattery.Announcement? = self.core.withLock {
                guard !self.terminal, self.activeAttempt == attempt, self.core.snapshot.ready,
                      self.registrations[registration.slot]?.identity == registration else { return nil }
                return self.battery.prepareAnnouncement(slot: registration.slot, backend: self.core.backend)
            }
            if let announcement { self.battery.report(announcement) }
        }
    }
}
