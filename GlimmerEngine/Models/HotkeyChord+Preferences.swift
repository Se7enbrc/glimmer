// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

extension HotkeyChord {
    /// Move only the old default once; a later explicit choice of Control-I belongs to the player.
    public static func persistedStats(defaults: UserDefaults = .standard) -> Self {
        let saved = defaults.data(forKey: "statsHotkey").flatMap {
            try? JSONDecoder().decode(Self.self, from: $0)
        }
        if let saved, defaults.bool(forKey: "statsControlZDefaultApplied") { return saved }
        let oldDefault = Self(ctrl: true, alt: false, shift: false, cmd: false, keyChar: "i")
        if let saved, saved != oldDefault {
            defaults.set(true, forKey: "statsControlZDefaultApplied")
            return saved
        }
        let owners: [(String, Self)] = [("quitHotkey", .defaultQuit),
                                      ("releasePointerHotkey", .defaultReleasePointer),
                                      ("miniPlayerHotkey", .defaultMiniPlayer)]
        let occupied = owners.map { key, fallback in
            defaults.data(forKey: key).flatMap { try? JSONDecoder().decode(Self.self, from: $0) } ?? fallback
        }
        let migrated = [Self.defaultStats, oldDefault].first { candidate in
            !occupied.contains { $0.serialized == candidate.serialized }
        } ?? Self(ctrl: false, alt: false, shift: false, cmd: false, keyChar: "")
        // Keep pristine defaults absent, but persist a collision decision so it never silently moves later.
        if saved != nil || migrated != .defaultStats { migrated.persistStats(defaults: defaults) }
        return migrated
    }

    /// Mark explicit choices so the legacy-default migration can never replace them.
    public func persistStats(defaults: UserDefaults = .standard) {
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
