// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

extension HotkeyChord {
    /// Move only the old default once; a later explicit choice of Control-I belongs to the player.
    public static func persistedStats(defaults: UserDefaults = .standard) -> Self {
        let saved = defaults.data(forKey: "statsHotkey")
            .flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? .defaultStats
        guard !defaults.bool(forKey: "statsControlZDefaultApplied") else { return saved }
        let oldDefault = Self(ctrl: true, alt: false, shift: false, cmd: false, keyChar: "i")
        let migrated = saved == oldDefault ? .defaultStats : saved
        if saved == oldDefault, let data = try? JSONEncoder().encode(migrated) {
            defaults.set(data, forKey: "statsHotkey")
        }
        defaults.set(true, forKey: "statsControlZDefaultApplied")
        return migrated
    }

    public func recordingConflict(taken: [(name: String, chord: HotkeyChord)]) -> String? {
        if shift, !ctrl, !alt, !cmd {
            return "Add ⌃, ⌥ or ⌘. With ⇧ alone, every capital letter would trigger it."
        }
        if let owner = taken.first(where: { $0.chord.displayString == displayString }) {
            return "Already used for \(owner.name)."
        }
        return nil
    }
}
