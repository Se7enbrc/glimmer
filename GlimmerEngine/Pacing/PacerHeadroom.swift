// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import os

/// Published only when the shell reconciles existing jitter evidence; releases read engine storage.
package final class PacerHeadroom: Sendable {
    package static let shared = PacerHeadroom()
    package init() {}
    package struct Decision: Sendable {
        package let headroomLevel: Int
        package let generation: UInt64
    }
    private let storage = OSAllocatedUnfairLock(initialState: Decision(headroomLevel: 0, generation: 0))
    package var decision: Decision { storage.withLock { $0 } }
    package func publish(level: Int, generation: UInt64) {
        storage.withLock { $0 = Decision(headroomLevel: level, generation: generation) }
    }
}
