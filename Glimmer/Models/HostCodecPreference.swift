//
//  HostCodecPreference.swift
//
//  Per-host codec override. The DEFAULT is smart: the client advertises
//  everything this Mac can hardware-decode (VideoFormats.probedSupported) and
//  the RTSP negotiation picks the best the host can encode - AV1 if both
//  sides speak it, else HEVC, else H.264, with the 10-bit flavor riding the
//  HDR toggle. So "Automatic" already does the right thing on a host that
//  can't encode AV1 (e.g. an RTX 3080): it lands on HEVC with zero
//  configuration.
//
//  The override exists for the host that negotiates a codec it then handles
//  badly (broken AV1 driver, ancient encoder): it CAPS what we advertise for
//  that one host. Persisted like the cert pins - one UserDefaults key per
//  host id - so it never touches the migrated host blob.
//

import Foundation

enum HostCodecPreference: String, CaseIterable, Identifiable {
    case auto   // AV1 → HEVC → H.264, best both sides support (default)
    case hevc   // never advertise AV1 to this host
    case h264   // compatibility floor

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .auto: return "Automatic (AV1 when available)"
        case .hevc: return "HEVC"
        case .h264: return "H.264"
        }
    }

    /// Cap the probed client capability set for this preference. Lower
    /// formats always stay advertised - the cap removes ceilings, never
    /// fallbacks, so a misconfigured override can't fail a connection.
    func apply(to probed: VideoFormats) -> VideoFormats {
        switch self {
        case .auto:
            return probed
        case .hevc:
            return probed.subtracting([.av1, .av1Main10])
        case .h264:
            return probed.subtracting([.av1, .av1Main10, .hevc, .hevcMain10])
        }
    }

    // MARK: - Persistence (one key per host, pinned-cert pattern)

    private static func key(for hostID: String) -> String {
        "glimmer.codecPreference.\(hostID)"
    }

    static func load(for hostID: String) -> HostCodecPreference {
        guard let raw = UserDefaults.standard.string(forKey: key(for: hostID)),
              let pref = HostCodecPreference(rawValue: raw)
        else { return .auto }
        return pref
    }

    static func save(_ pref: HostCodecPreference, for hostID: String) {
        if pref == .auto {
            UserDefaults.standard.removeObject(forKey: key(for: hostID))
        } else {
            UserDefaults.standard.set(pref.rawValue, forKey: key(for: hostID))
        }
    }

    static func forget(hostID: String) {
        UserDefaults.standard.removeObject(forKey: key(for: hostID))
    }
}
