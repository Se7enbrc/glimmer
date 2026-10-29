// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

// Both route publication and packet-worker reads use this lock; no app call enters the receive loop.
package final class TransportRoute: @unchecked Sendable {
    package static let shared = TransportRoute()
    package init() {}

    private let lock = NSLock()
    private var label = "unknown"

    package var streamLink: String {
        get { lock.withLock { label } }
        set { lock.withLock { label = newValue } }
    }
}
