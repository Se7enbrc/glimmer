// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

extension StreamInput {
    /// Applies to current and future registrations; the default preserves the legacy Mac mapping.
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

    private func prepareControllerMouseMappingChange(slot: UInt8) {
        core.resetControllerMouse(slot: slot)
        core.releaseControllerTouches(slot: slot)
        core.releases.release(.controller(slot))
        core.flushReleases()
        core.current[slot] = nil
        core.updateChord(slot: slot, held: false, invalidate: true)
        core.controllerMouseStates[slot] = ControllerMouseState(isMouse: true)
        core.mousePollingGeneration &+= 1
        core.controllerMouseTimer?.cancel()
        core.controllerMouseTimer = nil
        core.updateControllerMousePolling()
        registrations[slot]?.rearm.suppressHeld()
        registrations[slot]?.acceptEventsAfter = ProcessInfo.processInfo.systemUptime
    }
}
