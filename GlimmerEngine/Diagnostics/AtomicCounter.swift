// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

/// A small thread-safe integer counter for in-flight send backpressure. NSLock is
/// sufficient (the few inc/dec/read sites are not in a tight inner loop), and it
/// matches the codebase's existing ManagedAtomicFlag style.
@usableFromInline package final class AtomicCounter: @unchecked Sendable {

    @inlinable package init() {}

    @usableFromInline internal let lock = NSLock()
    @usableFromInline internal var total = 0
    @inlinable package var value: Int { lock.lock(); defer { lock.unlock() }; return total }
    @inlinable package func increment() { lock.lock(); total += 1; lock.unlock() }
    @inlinable package func decrement() { lock.lock(); if total > 0 { total -= 1 }; lock.unlock() }
}
