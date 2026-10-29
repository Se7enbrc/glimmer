// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

extension StreamInput {
    public func setControllerMenuOpensControls(_ enabled: Bool) {
        core.withLock { core.controllerMenuOpensControls = enabled }
    }

    /// The native menu changes only the controller that opened it; stale registrations cannot affect a new pad.
    public func setControllerMouseMode(_ enabled: Bool, for registration: ControllerRegistration) {
        core.withLock {
            guard !terminal, registrations[registration.slot]?.identity == registration else { return }
            prepareControllerMouseMappingChange(slot: registration.slot, enabled: enabled)
            core.onMotionInputEnabled?(registration.slot, !enabled && core.snapshot.focused)
            emit(.mouseMode(registration, enabled: enabled))
            scheduleReconciliation()
        }
    }

    /// Applies to current and future registrations.
    /// A live change releases mouse input and rearms held controls before using the new mapping.
    public func setControllerMouseMapping(_ mapping: ControllerMouseMapping) {
        core.withLock {
            guard !terminal, core.controllerMouseMapping != mapping else { return }
            core.controllerMouseMapping = mapping
            for slot in registrations.keys where core.controllerMouseStates[slot]?.isMouse == true {
                prepareControllerMouseMappingChange(slot: slot)
            }
            scheduleReconciliation()
        }
    }

    public func setControllerMouseBindings(_ bindings: ControllerMouseBindings) {
        core.withLock {
            guard !terminal else { return }
            core.controllerMouseMapping = bindings.preset
            core.controllerMousePlan = ControllerMousePlan(bindings)
            for slot in registrations.keys where core.controllerMouseStates[slot]?.isMouse == true {
                prepareControllerMouseMappingChange(slot: slot)
            }
            scheduleReconciliation()
        }
    }

    private func prepareControllerMouseMappingChange(slot: UInt8, enabled: Bool = true) {
        core.resetControllerMouse(slot: slot)
        core.releaseControllerTouches(slot: slot)
        core.releases.release(.controller(slot))
        core.flushReleases()
        core.current[slot] = nil
        core.updateChord(slot: slot, held: false, invalidate: true)
        core.controllerMouseStates[slot] = ControllerMouseState(isMouse: enabled)
        core.mousePollingGeneration &+= 1
        core.controllerMouseTimer?.cancel()
        core.controllerMouseTimer = nil
        core.updateControllerMousePolling()
        registrations[slot]?.rearm.suppressHeld()
        registrations[slot]?.acceptEventsAfter = ProcessInfo.processInfo.systemUptime
    }
}
