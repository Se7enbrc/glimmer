// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Per-PC codec choices cap advertised capabilities without altering the paired-PC record.

import Foundation

package enum HostCodecPreference: String, CaseIterable, Identifiable {
    case auto   // AV1 → HEVC → H.264, best both sides support (default)
    case hevc   // never advertise AV1 to this host
    case h264   // compatibility floor

    package var id: String { rawValue }

    package var displayName: String {
        switch self {
        case .auto: return "Automatic (AV1 when available)"
        case .hevc: return "HEVC"
        case .h264: return "H.264"
        }
    }

    /// Cap the probed client capability set for this preference. Lower
    /// formats always stay advertised - the cap removes ceilings, never
    /// fallbacks, so a misconfigured override can't fail a connection.
    package func apply(to probed: VideoFormats) -> VideoFormats {
        switch self {
        case .auto:
            return probed
        case .hevc:
            return probed.subtracting(.anyAV1)
        case .h264:
            return probed.subtracting(.anyAV1.union(.anyHEVC))
        }
    }

    // MARK: - Persistence (one key per host, pinned-cert pattern)

    private static func key(for hostID: String) -> String {
        "glimmer.codecPreference.\(hostID)"
    }

    package static func load(for hostID: String, defaults: UserDefaults = .standard) -> HostCodecPreference {
        guard let raw = defaults.string(forKey: key(for: hostID)),
              let pref = HostCodecPreference(rawValue: raw)
        else { return .auto }
        return pref
    }

    package static func save(_ pref: HostCodecPreference, for hostID: String, defaults: UserDefaults = .standard) {
        defaults.set(pref.rawValue, forKey: key(for: hostID))
    }

    package static func forget(hostID: String, defaults: UserDefaults = .standard) {
        defaults.removeObject(forKey: key(for: hostID))
    }
}
