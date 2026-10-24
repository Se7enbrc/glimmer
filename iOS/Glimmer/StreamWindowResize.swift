// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

@MainActor
final class StreamWindowResize {
    enum Result: Sendable { case applied, deferred, rejected }
    typealias Request = @MainActor @Sendable (StreamFormat) async -> Result

    private let request: Request
    private let applied: (StreamFormat) -> Void
    private let sleep: @Sendable (Duration) async throws -> Void
    private var current: StreamFormat
    private var desired: StreamFormat
    private var available = false
    private var stopped = false
    private var applying = false
    private var task: Task<Void, Never>?

    init(format: StreamFormat, request: @escaping Request, applied: @escaping (StreamFormat) -> Void,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        current = format
        desired = format
        self.request = request
        self.applied = applied
        self.sleep = sleep
    }

    func submit(_ format: StreamFormat) {
        guard !stopped, desired != format else { return }
        desired = format
        if !applying { task?.cancel(); task = nil }
        schedule()
    }

    func setAvailable(_ value: Bool) {
        available = value
        if !value, !applying { task?.cancel(); task = nil }
        if value { schedule() }
    }

    func stop() {
        stopped = true
        task?.cancel()
    }

    func waitForPendingChange() async { await task?.value }

    private func schedule() {
        guard !stopped, available, task == nil, desired != current else { return }
        let target = desired
        task = Task { [weak self, sleep] in
            do { try await sleep(.milliseconds(750)) } catch { return }
            guard !Task.isCancelled, let self, !stopped, available, desired == target else { return }
            applying = true
            let result = await request(target)
            applying = false
            task = nil
            guard !Task.isCancelled, !stopped else { return }
            if case .applied = result {
                current = target
                applied(target)
            }
            // A deferred target waits for fresh lifecycle evidence, rather than polling the PC.
            if desired != target { schedule() }
        }
    }
}
