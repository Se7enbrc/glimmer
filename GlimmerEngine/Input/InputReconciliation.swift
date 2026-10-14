// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

package enum InputReconciliation {
    @MainActor
    package static func makeTimer(_ tick: @escaping @MainActor @Sendable () -> Void) -> Timer {
        let timer = Timer(timeInterval: 0.25, repeats: true) { _ in MainActor.assumeIsolated { tick() } }
        timer.tolerance = 0.025
        RunLoop.main.add(timer, forMode: .common)
        return timer
    }
}

extension StreamInput {
    func scheduleReconciliation() {
        guard !terminal, needsReconciliation, !reconciliationScheduled else { return }
        reconciliationScheduled = true
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.core.withLock {
                guard !self.terminal, self.needsReconciliation else {
                    self.reconciliationScheduled = false
                    return
                }
                self.reconciliationTimer = InputReconciliation.makeTimer { [weak self] in self?.reconcile() }
            }
        }
    }

    var needsReconciliation: Bool {
        core.snapshot.ready && (!core.releases.pending.isEmpty || !core.pendingTouchReleases.isEmpty
            || registrations.values.contains { !$0.announced })
    }

    @MainActor
    func reconcile() {
        core.withLock {
            if !terminal {
                _ = core.flushReleases()
                for registration in registrations.values where !registration.announced {
                    announce(registration.identity)
                }
            }
            guard terminal || !needsReconciliation else { return }
            reconciliationTimer?.invalidate()
            reconciliationTimer = nil
            reconciliationScheduled = false
        }
    }
}
