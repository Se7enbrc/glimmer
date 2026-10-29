// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Observation
import UIKit

@MainActor
@Observable
final class StreamMenuVisibility {
    private(set) var visible = false
    @ObservationIgnored private var playing = false
    @ObservationIgnored private var voiceOver: Bool
    @ObservationIgnored private(set) var hideTask: Task<Void, Never>?
    @ObservationIgnored private let sleep: @Sendable (Duration) async throws -> Void
    @ObservationIgnored private let announce: (String) -> Void

    init(voiceOver: Bool = UIAccessibility.isVoiceOverRunning,
         sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) },
         announce: @escaping (String) -> Void = { UIAccessibility.post(notification: .announcement, argument: $0) }) {
        self.voiceOver = voiceOver
        self.sleep = sleep
        self.announce = announce
    }

    isolated deinit { hideTask?.cancel() }

    var hasPendingHide: Bool { hideTask != nil }

    func setPlaying(_ playing: Bool) {
        guard self.playing != playing else { return }
        self.playing = playing
        if playing {
            reveal()
            if voiceOver { announce("Stream controls available.") }
        } else {
            hideTask?.cancel()
            hideTask = nil
            visible = false
        }
    }

    func voiceOverChanged(_ enabled: Bool) {
        guard voiceOver != enabled else { return }
        voiceOver = enabled
        guard playing else { return }
        reveal()
        if enabled { announce("Stream controls available.") }
    }

    func reveal() {
        guard playing else { return }
        hideTask?.cancel()
        hideTask = nil
        visible = true
        guard !voiceOver else { return }
        hideTask = Task { [weak self, sleep] in
            do { try await sleep(.seconds(2)) } catch { return }
            guard !Task.isCancelled else { return }
            self?.visible = false
            self?.hideTask = nil
        }
    }

    func waitForPendingHide() async { await hideTask?.value }
}
