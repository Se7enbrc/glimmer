// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

public enum HostReadiness {
    public nonisolated static func isReadyForStream(_ info: ServerInfo) -> Bool {
        info.currentGameID == 0 && !info.isBusy
    }

    /// A failed reply proves nothing; keep checking until idle or the shared wall-clock bound.
    @MainActor public static func pollReadiness(
        until deadline: Date,
        fetch: @escaping @Sendable () async throws -> ServerInfo,
        busy: () -> Void = {},
        now: () -> Date = Date.init,
        sleep: (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) async -> ServerInfo? {
        var lastAnswer: ServerInfo?
        while !Task.isCancelled, now() < deadline {
            do {
                let info = try await StreamAttempt.run(until: deadline, operation: fetch)
                lastAnswer = info
                if isReadyForStream(info) { return info }
                busy()
            } catch {
                if Task.isCancelled { return nil }
            }
            do { try await sleep(min(0.5, max(0, deadline.timeIntervalSince(now())))) } catch { return nil }
        }
        return Task.isCancelled ? nil : lastAnswer
    }
}
