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
/// `gMax` is derived from stream width; tuning is read once per stream.
enum CruiseTraversal {
    /// Master gate. HIDDEN, default-TRUE (registered in GlimmerApp beside the
    /// other input defaults) - an escape hatch for purists, with no Settings row.
    static let enabledDefaultsKey = "cruiseTraversalEnabled"
    /// HIDDEN tune knobs (a standing tune-grant); NOT surfaced in UI. Velocities
    /// are in raw HID counts/sec. Read once per stream so a live `defaults
    /// write` takes effect on the next stream without a rebuild.
    static let vKneeDefaultsKey = "cruiseVKnee"
    static let vFullDefaultsKey = "cruiseVFull"
    /// The reference width the gain is normalized against: at this width gMax==1.0
    /// (fully inert). 1920 → 4K(3840) gives gMax 2.0, 1440p(2560) ~1.33, 1080p 1.0.
    static let referenceWidth: Double = 1920
    /// Defaults for the velocity gate (counts/sec). Below `vKnee` the gain is
    /// exactly 1.0; at/above `vFull` it is the full `gMax`; between, a smoothstep.
    /// CALIBRATION NOTE: earlier bands (1400/4500, then 2000/3200) were tuned
    /// against the old per-batch dist/dt estimator, whose tiny-dt spikes read
    /// ~2x high. Under the honest windowed estimator the field distribution is
    /// p50~220 / p90~750 / p99~1770 with precision aim topping out ~920, so
    /// 1100/1800 keeps aim raw with margin and puts real flicks AT gMax
    /// (validated live 2026-07-19; the 2000 knee left the boost engaging on
    /// ~0.03% of batches - effectively off).
    static let defaultVKnee: Double = 1100
    static let defaultVFull: Double = 1800

    /// DRAG-DELTA compensation, applied only while raw aim is engaged: that mode
    /// damped *MouseDragged deltas to ~0.6-0.7x of free motion (owner-measured,
    /// macOS 27 beta). Hidden per-stream tuning; 1.0 disables; clamped.
    static let dragDeltaScaleDefaultsKey = "cruiseDragDeltaScale"
    static let defaultDragDeltaScale: Double = 1.35
    struct Tuning {
        let enabled: Bool
        let vKnee: Double
        let vFull: Double
        let dragDeltaScale: Double

        static func current(_ defaults: UserDefaults = .standard) -> Tuning {
            let kneeValue = defaults.double(forKey: vKneeDefaultsKey)
            let knee = kneeValue > 0 ? kneeValue : defaultVKnee
            let fullValue = defaults.double(forKey: vFullDefaultsKey)
            let full = fullValue > knee ? fullValue : max(defaultVFull, knee + 1)
            let scaleValue = defaults.double(forKey: dragDeltaScaleDefaultsKey)
            let scale = scaleValue > 0 ? min(max(scaleValue, 0.5), 3.0) : defaultDragDeltaScale
            return Tuning(enabled: defaults.bool(forKey: enabledDefaultsKey), vKnee: knee,
                          vFull: full, dragDeltaScale: scale)
        }
    }

    /// Resolution-derived ceiling for the boost. Clamped to >=1.0 so <=1080p is
    /// provably inert (gMax==1.0 ⇒ gain is 1.0 at every velocity).
    static func gMax(forStreamWidth width: Int) -> Double {
        max(1.0, Double(width) / referenceWidth)
    }

    @MainActor
    static func configure(_ forwarder: InputForwarder, streamWidth: Int) {
        forwarder.cruiseGMax = forwarder.cruiseTuning.enabled ? gMax(forStreamWidth: streamWidth) : 1.0
    }

    /// The pure gain. `velocity` is the batch speed (counts/sec); `dt` is the
    /// inter-batch interval (NSEvent.timestamp deltas). Returns 1.0 on a
    /// stale/post-gap dt and in the sacred low-speed aim band (EARLY RETURN, no
    /// float round-trip), gMax at/above full speed, and a C1 smoothstep ramp
    /// between. With gMax==1.0 every branch yields 1.0, so the whole feature is
    /// inert at <=referenceWidth.
    static func gain(velocity: Double, dt: Double, gMax: Double,
                     vKnee: Double, vFull: Double) -> Double {
        if dt <= 0 || dt > 0.1 { return 1.0 }   // stale/post-gap dt -> identity
        if velocity <= vKnee { return 1.0 }      // sacred aim band, unscaled
        if velocity >= vFull { return gMax }
        // Flooring vFull above vKnee keeps the smoothstep denominator positive.
        let ramp = (velocity - vKnee) / (vFull - vKnee)
        let s = ramp * ramp * (3 - 2 * ramp)     // smoothstep, C1 at both ends
        return 1.0 + (gMax - 1.0) * s
    }
}
