// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

extension StreamInput {
    /// Revocation and releases complete against the old uplink before the session closes its transport.
    /// Physical registrations and native capture leases survive an internal recovery attempt.
    package func prepareForReplacement(attempt: UUID) {
        core.withLock {
            guard !terminal, activeAttempt == attempt else { return }
            activeAttempt = nil
            rearmOnActivation = true
            haptics.stopAll(reason: "connection replaced")
            motion.stopAll(reason: "connection replaced")
            battery.pause()
            releaseOwnership()
            core.releases.releaseAll(connectionLost: true)
            core.snapshot.ready = false
            core.snapshot.focused = false
            core.snapshot.acceptEventsAfter = ProcessInfo.processInfo.systemUptime
            core.backend = nil
            core.pendingArrivals.removeAll()
            core.current.removeAll()
            core.buttons.removeAll()
            core.analogs.removeAll()
            for slot in registrations.keys {
                registrations[slot]?.announced = false
                registrations[slot]?.rearm.suppressHeld()
            }
            emit(.controllersActive(false))
        }
    }

    /// Only a detached, nonterminal owner can adopt a new attempt; no backend is allocated here.
    @discardableResult
    package func rebind(to backend: any StreamingBackend, attempt: UUID, holdActivation: Bool = false) -> Bool {
        core.withLock {
            guard !terminal, activeAttempt == nil, core.backend == nil else { return false }
            activeAttempt = attempt
            self.holdActivation = holdActivation
            var snapshot = core.snapshot
            snapshot.ready = false
            snapshot.focused = false
            core.publish(snapshot, backend: backend)
            core.snapshot.acceptEventsAfter = ProcessInfo.processInfo.systemUptime
            for slot in registrations.keys {
                registrations[slot]?.announced = false
                registrations[slot]?.rearm.suppressHeld()
            }
            return true
        }
    }

    package func resumeAfterReplacement(attempt: UUID) {
        core.withLock {
            guard activeAttempt == attempt else { return }
            holdActivation = false
            activate(true, attempt: attempt)
        }
    }

    /// The immutable attempt identity is captured before queuing; stale activation cannot rebind itself.
    package func enqueueActivation(_ value: Bool, attempt: UUID) {
        lifecycleQueue.async { [weak self] in self?.activate(value, attempt: attempt) }
    }
}
