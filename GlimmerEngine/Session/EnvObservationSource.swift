// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

/// Sampling closures are immutable; the lock transfers native cleanup exactly once.
/// Abandoned preparation also releases the probes, before a session can adopt them.
package final class EnvObservationSource: @unchecked Sendable {
    let route: @Sendable () -> StreamRouteSnapshot?
    let wifi: @Sendable () -> WiFiSnapshot?
    private let lock = NSLock()
    private var cleanup: (@Sendable () -> Void)?

    package init(route: @escaping @Sendable () -> StreamRouteSnapshot?,
                 wifi: @escaping @Sendable () -> WiFiSnapshot?,
                 stop: @escaping @Sendable () -> Void) {
        self.route = route
        self.wifi = wifi
        cleanup = stop
    }

    deinit { stop() }

    package func stop() {
        let operation = lock.withLock {
            let operation = cleanup
            cleanup = nil
            return operation
        }
        operation?()
    }
}
