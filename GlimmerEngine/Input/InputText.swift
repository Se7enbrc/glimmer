// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

/// Shared text preparation and release-channel ordering; native adapters retain keyboard event ownership.
package enum InputText {
    package static let maxBytes = 4096

    package static func prepared(_ text: String) -> String {
        var result = ""
        var bytes = 0
        for character in text.replacingOccurrences(of: "\r\n", with: "\n") {
            bytes += character.utf8.count
            guard bytes <= maxBytes else { break }
            result.append(character)
        }
        return result
    }

    /// Text waits for releases on the other reliable channel, retaining the original connection.
    @MainActor
    package static func send(_ text: String, core: InputCore, waitForRelease: Bool,
                             isCurrent: @escaping @MainActor () -> Bool,
                             flushReleases: @escaping @MainActor () -> Bool,
                             finished: @escaping @MainActor () async -> Void) -> Task<Void, Never>? {
        guard !text.isEmpty, isCurrent(), let backend = core.withLock({ core.backend }) else { return nil }
        let attempt: @MainActor () -> Bool = {
            core.withLock {
                guard isCurrent(), core.backend === backend, flushReleases() else { return false }
                core.record("LiSendUtf8TextEvent", backend.sendUtf8Text(text))
                return true
            }
        }
        if !waitForRelease, attempt() { return nil }
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(50))
        return Task {
            try? await Task.sleep(until: deadline, clock: .continuous)
            while !Task.isCancelled, isCurrent(), core.withLock({ core.backend === backend }) {
                if attempt() { break }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
            }
            await finished()
        }
    }
}
