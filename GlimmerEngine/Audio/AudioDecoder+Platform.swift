// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

extension AudioDecoder {
    var logID: String { String(UInt(bitPattern: ObjectIdentifier(self)), radix: 16) }

    func installAudioRouteListener(initial route: AudioRoute) {
        audioMeterLock.withLock { audioRouteCache = route.label }
        Diag.notice("audio output route: \(route.label, privacy: .private)", "Stream")
        let generation = engineRestartGeneration
        platform.installRouteListener(routeListenerQueue, logID) { [weak self] changedAt in
            self?.noteRouteChange(at: changedAt, generation: generation)
        }
    }

    private func noteRouteChange(at changedAt: UInt64, generation: UInt64) {
        let fresh = platform.sampleRoute()
        beginGraphChange()
        guard !isShutdown, generation == engineRestartGeneration else { endGraphChange(); return }
        let previous = audioMeterLock.withLock {
            let previous = audioRouteCache
            audioRouteCache = fresh.label
            noteOutputDeviceLocked(uid: fresh.uid)
            return previous
        }
        endGraphChange()
        if fresh.label != previous {
            Diag.notice("audio route changed: \(previous, privacy: .private) → "
                + "\(fresh.label, privacy: .private)", "Stream")
        }
        handleEngineConfigurationChange(changedAt: changedAt, generation: generation)
    }

    func removeAudioRouteListener() { platform.removeRouteListener(logID) }

    func installDeviceListeners() {
        let generation = engineRestartGeneration
        platform.installDeviceListeners(routeListenerQueue) { [weak self] changedAt in
            self?.handleEngineConfigurationChange(changedAt: changedAt, generation: generation)
        }
    }

    func removeDeviceListeners() { platform.removeDeviceListeners() }
}
