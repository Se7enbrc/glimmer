// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Read saved choices without turning current defaults into persistent values.

import GlimmerEngine
import Foundation

extension AppModel {

    /// A positive `Int`, or nil when the key is absent (`integer(forKey:)`
    /// returns 0) or non-positive.
    static func persistedPositiveInt(_ key: String, defaults: UserDefaults = PersistentStorage.defaults) -> Int? {
        let value = defaults.integer(forKey: key)
        return value > 0 ? value : nil
    }

    /// A `Bool`, or nil when the key was never written (so the default holds).
    static func persistedBool(_ key: String, defaults: UserDefaults = PersistentStorage.defaults) -> Bool? {
        guard defaults.object(forKey: key) != nil else { return nil }
        return defaults.bool(forKey: key)
    }

    /// Only retired enum cases migrate; never infer intent from a value matching a default.
    static func persistedQualityPreset(defaults: UserDefaults = PersistentStorage.defaults) -> QualityPreset? {
        guard let raw = defaults.string(forKey: "qualityPreset") else { return nil }
        let preset = QualityPreset.migrated(fromPersistedRawValue: raw)
        if raw != preset.rawValue {
            defaults.set(preset.rawValue, forKey: "qualityPreset")
        }
        return preset
    }

    /// Decode a string-backed `RawRepresentable` from its persisted raw value.
    static func persistedRawValue<T: RawRepresentable>(
        _ key: String, _ type: T.Type, defaults: UserDefaults = PersistentStorage.defaults
    ) -> T? where T.RawValue == String {
        guard let raw = defaults.string(forKey: key) else { return nil }
        return T(rawValue: raw)
    }

    /// JSON-decode a `Codable` from its persisted data blob.
    static func persistedDecoded<T: Decodable>(
        _ key: String, _ type: T.Type, defaults: UserDefaults = PersistentStorage.defaults) -> T? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Move only the old stats default once, preserving later choices of ⌃I.
    static func persistedStatsHotkey(defaults: UserDefaults = PersistentStorage.defaults) -> HotkeyChord {
        HotkeyChord.persistedStats(defaults: defaults)
    }

    /// Stored values carry intent even when they equal a previous default.
    static func persistedStatsThresholds(defaults: UserDefaults = PersistentStorage.defaults) -> StatsThresholds {
        persistedDecoded("statsThresholds", StatsThresholds.self, defaults: defaults) ?? .default
    }

    /// Decode the persisted stats-overlay custom-row set, or nil when the key is
    /// absent or contains only unknown names. An explicit empty set stays empty.
    static func persistedCustomRows(defaults: UserDefaults = PersistentStorage.defaults) -> Set<StatsRow.Kind>? {
        guard let raw = defaults.array(forKey: "statsOverlayCustomRows") as? [String] else {
            return nil
        }
        let decoded = raw.compactMap(StatsRow.Kind.init(rawValue:))
        return !raw.isEmpty && decoded.isEmpty ? nil : Set(decoded)
    }
}
