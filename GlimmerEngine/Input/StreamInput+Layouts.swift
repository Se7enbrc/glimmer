// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

extension StreamInput {
    public func setControllerLayout(_ configuration: ControllerLayoutConfiguration?, for registration: ControllerRegistration,
                                    held: ControllerMappingSample = .init(), systemHeld: ControllerMappingSample? = nil) {
        core.withLock {
            guard !terminal, registrations[registration.slot]?.identity == registration else { return }
            let now = ProcessInfo.processInfo.systemUptime
            registrations[registration.slot]?.acceptEventsAfter = now
            registrations[registration.slot]?.rearm.suppressHeld()
            core.configureLayout(configuration, slot: registration.slot, held: held, at: now, systemHeld: systemHeld)
            invalidateChordContext()
            scheduleReconciliation()
        }
    }

    public func observeControllerEscape(_ handler: (@Sendable () -> Void)?) {
        core.withLock { core.onControllerEscape = handler }
    }
}
