//
//  AppModel+Defaults.swift
//
//  The typed UserDefaults read helpers `AppModel.init()` loads its persisted
//  settings through, plus the quality-preset migration. Split out of
//  AppModel.swift to keep each unit focused (and that file under its length
//  limit); they are `static` rather than file-private precisely so the
//  initializer over there can still reach them.
//

import Foundation

extension AppModel {

    // MARK: - Persisted-setting decode helpers
    //
    // Small typed wrappers around UserDefaults so `init()` reads as a flat list
    // of assignments instead of a branch per key. Each returns nil when the key
    // is absent / out of range / undecodable, so the caller keeps the property's
    // declared default - identical to the prior inline `if let` / `if x > 0`.

    /// A positive `Int`, or nil when the key is absent (`integer(forKey:)`
    /// returns 0) or non-positive.
    static func persistedPositiveInt(_ key: String) -> Int? {
        let value = UserDefaults.standard.integer(forKey: key)
        return value > 0 ? value : nil
    }

    /// A `Bool`, or nil when the key was never written (so the default holds).
    static func persistedBool(_ key: String) -> Bool? {
        guard UserDefaults.standard.object(forKey: key) != nil else { return nil }
        return UserDefaults.standard.bool(forKey: key)
    }

    /// The persisted quality preset, with the presets dropped in the rework
    /// remapped to their surviving equivalents
    /// (`QualityPreset.migrated(fromPersistedRawValue:)` owns the mapping).
    /// nil when the key is absent, so the property's declared default holds and
    /// nothing is written for a user who never picked a preset.
    ///
    /// One-shot: the migrated value is written back only when it actually
    /// differs from what was on disk, so a legacy string is rewritten exactly
    /// once and every later launch takes the plain decode path. Idempotent -
    /// re-running over an already-migrated key writes nothing.
    static func persistedQualityPreset() -> QualityPreset? {
        guard let raw = UserDefaults.standard.string(forKey: "qualityPreset") else { return nil }
        let preset = QualityPreset.migrated(fromPersistedRawValue: raw)
        if raw != preset.rawValue {
            UserDefaults.standard.set(preset.rawValue, forKey: "qualityPreset")
        }
        return preset
    }

    /// Decode a string-backed `RawRepresentable` from its persisted raw value.
    static func persistedRawValue<T: RawRepresentable>(
        _ key: String, _ type: T.Type
    ) -> T? where T.RawValue == String {
        guard let raw = UserDefaults.standard.string(forKey: key) else { return nil }
        return T(rawValue: raw)
    }

    /// JSON-decode a `Codable` from its persisted data blob.
    static func persistedDecoded<T: Decodable>(_ key: String, _ type: T.Type) -> T? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(type, from: data)
    }

    /// Decode the persisted stats-overlay custom-row set, or nil when the key is
    /// absent or decodes to an empty set (so the default initial set holds).
    static func persistedCustomRows() -> Set<StatsRow.Kind>? {
        guard let raw = UserDefaults.standard.array(forKey: "statsOverlayCustomRows") as? [String] else {
            return nil
        }
        let decoded = raw.compactMap(StatsRow.Kind.init(rawValue:))
        return decoded.isEmpty ? nil : Set(decoded)
    }
}
