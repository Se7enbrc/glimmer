// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import UIKit

@MainActor
final class StreamBackgroundGrace {
    static let duration: TimeInterval = 15

    @MainActor
    struct Calls {
        var begin: @MainActor (@escaping @MainActor @Sendable () -> Void) -> UIBackgroundTaskIdentifier = {
            UIApplication.shared.beginBackgroundTask(withName: "Disconnect stream", expirationHandler: $0)
        }
        var end: @MainActor (UIBackgroundTaskIdentifier) -> Void = { UIApplication.shared.endBackgroundTask($0) }
        var now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
        var sleep: @Sendable () async throws -> Void = { try await Task.sleep(for: .seconds(duration)) }
    }

    private let calls: Calls
    private var identifier: UIBackgroundTaskIdentifier = .invalid
    private var deadline: TimeInterval?
    private var timer: Task<Void, Never>?
    private var generation: UInt64 = 0

    init(calls: Calls = Calls()) { self.calls = calls }

    func prepare(expired: @escaping @MainActor @Sendable () -> Void) {
        guard identifier == .invalid else { return }
        generation &+= 1
        let attempt = generation
        identifier = calls.begin { [weak self] in
            guard let self, generation == attempt else { return }
            expired()
            finish()
        }
    }

    func leave(expired: @escaping @MainActor @Sendable () -> Void) {
        guard deadline == nil else { return }
        guard identifier != .invalid else { expired(); return }
        deadline = calls.now() + Self.duration
        let attempt = generation
        timer = Task { [weak self, calls] in
            do { try await calls.sleep() } catch { return }
            guard let self, generation == attempt, !Task.isCancelled else { return }
            expired()
        }
    }

    func returned() -> Bool {
        let expired = deadline.map { calls.now() >= $0 } ?? false
        finish()
        return !expired
    }

    func finish() {
        generation &+= 1
        timer?.cancel()
        timer = nil
        deadline = nil
        if identifier != .invalid {
            let previous = identifier
            identifier = .invalid
            calls.end(previous)
        }
    }

    isolated deinit { finish() }
}
