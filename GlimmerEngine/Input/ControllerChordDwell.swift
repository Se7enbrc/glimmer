// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

/// One dwell scheduler for all capture adapters. Each expiry re-reads live held state.
@MainActor
package final class ControllerChordDwell {
    package private(set) var task: Task<Void, Never>?
    package private(set) var slot: UInt8?
    private var generation = UUID()
    private var context: UUID?
    private struct Request {
        let edge: UUID?
        let held: @MainActor () -> Bool
        let armed: @MainActor () -> Void
        let expired: @MainActor (Bool) -> Void
    }
    private var requests: [UInt8: Request] = [:]
    private var order: [UInt8] = []

    nonisolated package init() {}
    deinit { task?.cancel() }

    package func synchronize(context: UUID) {
        guard self.context != context else { return }
        self.context = context
        cancel()
    }

    package func arm(slot: UInt8, edge: UUID? = nil, held: @escaping @MainActor () -> Bool,
                     armed: @escaping @MainActor () -> Void = {},
                     expired: @escaping @MainActor (Bool) -> Void) {
        let request = Request(edge: edge, held: held, armed: armed, expired: expired)
        if let existing = requests[slot], existing.edge == edge {
            requests[slot] = request
            return
        }
        if requests[slot] != nil { cancel(slot: slot) }
        requests[slot] = request
        order.append(slot)
        startNext()
    }

    package func cancel(slot: UInt8? = nil) {
        if let slot {
            requests[slot] = nil
            order.removeAll { $0 == slot }
            guard self.slot == slot else { return }
        } else {
            requests.removeAll()
            order.removeAll()
        }
        generation = UUID()
        task?.cancel()
        task = nil
        self.slot = nil
        startNext()
    }

    package func expire() {
        guard let slot, let request = requests.removeValue(forKey: slot) else { return }
        order.removeAll { $0 == slot }
        task?.cancel()
        task = nil
        self.slot = nil
        request.expired(request.held())
        startNext()
    }

    private func startNext() {
        guard task == nil, let next = order.first, let request = requests[next] else { return }
        slot = next
        generation = UUID()
        let token = generation
        request.armed()
        task = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(ControllerChord.dwellSeconds * 1_000_000_000))
            guard !Task.isCancelled, let self, self.generation == token else { return }
            self.expire()
        }
    }
}
