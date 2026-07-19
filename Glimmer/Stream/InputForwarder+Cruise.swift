//
//  InputForwarder+Cruise.swift
//
//  "Cruise": a velocity-gated, resolution-derived traversal boost for relative
//  mouse motion. Glimmer forwards raw HID deltas and linearizes the Mac's
//  pointer accel (raw-aim, default-on), which removed the acceleration that used
//  to let a fast flick cover the whole screen - so at 4K the cursor feels slow to
//  traverse. Cruise restores fast-traversal coverage WITHOUT touching aim: it
//  applies a gain >1 ONLY to fast movements, derived purely from the stream
//  resolution. Below the knee the gain is exactly 1.0 (the sacred aim band, byte-
//  identical to today). Same save→read discipline as MouseAccelerationControl.
//
//  Runs AFTER the Mac linearization - it is the only client-side gain, so there
//  is no double-accel. No wire/host/protocol change: still relative LiSendMouseMove.
//

import Foundation

// MARK: - Cruise traversal-boost gain

/// Pure gain function + constants for the resolution-compensated traversal boost.
/// `gMax` is DERIVED from the stream width (never user-dialed); the knee/full
/// velocities are HIDDEN UserDefaults tunables with no UI surface - the owner
/// wants zero user-facing controls, so this is "magic only".
enum CruiseTraversal {
    /// Master gate. HIDDEN, default-TRUE (registered in GlimmerApp beside the
    /// other input defaults) - an escape hatch for purists, with no Settings row.
    static let enabledDefaultsKey = "cruiseTraversalEnabled"
    /// HIDDEN tune knobs (a standing tune-grant); NOT surfaced in UI. Velocities
    /// are in raw HID counts/sec. Read once per gain call so a live `defaults
    /// write` takes effect on the next stream without a rebuild.
    static let vKneeDefaultsKey = "cruiseVKnee"
    static let vFullDefaultsKey = "cruiseVFull"
    /// The reference width the gain is normalized against: at this width gMax==1.0
    /// (fully inert). 1920 → 4K(3840) gives gMax 2.0, 1440p(2560) ~1.33, 1080p 1.0.
    static let referenceWidth: Double = 1920
    /// Defaults for the velocity gate (counts/sec). Below `vKnee` the gain is
    /// exactly 1.0; at/above `vFull` it is the full `gMax`; between, a smoothstep.
    /// Re-tuned from 1400/4500 on 14d of field data: real flicks peak ~3200
    /// counts/s, so half of all sessions never reached full gain (max 1.06-1.57)
    /// and fast aim above 1400 was getting nibbled - the "mushy" mid-band. The
    /// 2000/3200 band keeps aim raw to 2000 and puts real flicks AT gMax.
    static let defaultVKnee: Double = 2000
    static let defaultVFull: Double = 3200

    /// Whether the feature is on (default true).
    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledDefaultsKey) }

    /// `vKnee` / `vFull` from defaults, falling back to the constants above when a
    /// key is absent or non-positive. `vFull` is floored just above `vKnee` so the
    /// smoothstep denominator can never be zero/negative.
    static var vKnee: Double {
        let v = UserDefaults.standard.double(forKey: vKneeDefaultsKey)
        return v > 0 ? v : defaultVKnee
    }
    static var vFull: Double {
        let v = UserDefaults.standard.double(forKey: vFullDefaultsKey)
        return v > vKnee ? v : max(defaultVFull, vKnee + 1)
    }

    /// Resolution-derived ceiling for the boost. Clamped to >=1.0 so <=1080p is
    /// provably inert (gMax==1.0 ⇒ gain is 1.0 at every velocity).
    static func gMax(forStreamWidth width: Int) -> Double {
        max(1.0, Double(width) / referenceWidth)
    }

    /// The pure gain. `v` is the batch speed (counts/sec); `dt` is the inter-batch
    /// interval (NSEvent.timestamp deltas). Returns 1.0 on a stale/post-gap dt and
    /// in the sacred low-speed aim band (EARLY RETURN, no float round-trip), gMax
    /// at/above full speed, and a C1 smoothstep ramp between. With gMax==1.0 every
    /// branch yields 1.0, so the whole feature is inert at <=referenceWidth.
    static func gain(velocity v: Double, dt: Double, gMax: Double,
                     vKnee: Double, vFull: Double) -> Double {
        if dt <= 0 || dt > 0.1 { return 1.0 }   // stale/post-gap dt -> identity
        if v <= vKnee { return 1.0 }             // sacred aim band, unscaled
        if v >= vFull { return gMax }
        let t = (v - vKnee) / (vFull - vKnee)
        let s = t * t * (3 - 2 * t)              // smoothstep, C1 at both ends
        return 1.0 + (gMax - 1.0) * s
    }
}
