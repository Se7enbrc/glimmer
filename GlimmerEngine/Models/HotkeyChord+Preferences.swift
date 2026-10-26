// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

extension HotkeyChord {
    /// Move only the old default once; a later explicit choice of Control-I belongs to the player.
    public static func persistedStats(defaults: UserDefaults = PersistentStorage.defaults) -> Self {
        guard let data = defaults.data(forKey: "statsHotkey"),
              let saved = try? JSONDecoder().decode(Self.self, from: data) else { return .defaultStats }
        guard !defaults.bool(forKey: "statsControlZDefaultApplied") else { return saved }
        let oldDefault = Self(ctrl: true, alt: false, shift: false, cmd: false, keyChar: "i")
        let migrated = saved == oldDefault ? .defaultStats : saved
        if saved == oldDefault, let data = try? JSONEncoder().encode(migrated) {
            defaults.set(data, forKey: "statsHotkey")
        }
        defaults.set(true, forKey: "statsControlZDefaultApplied")
        return migrated
    }

    /// Mark explicit choices so the legacy-default migration can never replace them.
    public func persistStats(defaults: UserDefaults = PersistentStorage.defaults) {
        guard let data = try? JSONEncoder().encode(self) else { return }
        defaults.set(data, forKey: "statsHotkey")
        defaults.set(true, forKey: "statsControlZDefaultApplied")
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
