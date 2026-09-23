//
//  AudioDecoder+Resampler.swift
//
//  The DRIFT-TRACKING RESAMPLER: the varispeed PI loop that repays the standing
//  host↔Mac clock offset, plus the per-device skew memory that seeds it
//  pre-converged. Split out of AudioDecoder+CushionMemory.swift - same idiom as
//  the FramePacer split, to keep that file under the length limit. It sat there
//  because it guards the same cushion the loss floor does, but it is its own
//  mechanism (a rate loop, not a depth policy) with its own UserDefaults bucket
//  ("host|device UID", not "host|link"), so it reads cleaner as a sibling. The
//  stored PI state stays on the class (stored properties can't live in
//  extensions); see the property docs in AudioDecoder.swift for the locking
//  rationale.
//

import AVFoundation
import Foundation

extension AudioDecoder {

    // MARK: - Resampler skew persistence (per host + output device)

    /// UserDefaults key prefix; full key = prefix + "host|device UID". The skew is
    /// between the PC's clock and the OUTPUT DEVICE's clock, so each device keeps
    /// its own record; the old host-only keys are never read.
    static let resamplerSkewKeyPrefix = "audioResamplerSkew."
    /// Read-side age half-life. Crystal skew is hardware-stable across days; a
    /// week halves a stale record toward 0 so junk can't outlive its host.
    static let resamplerSkewAgeHalfLifeSeconds: Double = 7 * 24 * 3600
    /// Below this |ppm| neither persist nor seed - the PI re-converges from 0
    /// in seconds at that scale and the write is churn.
    static let resamplerSkewMinPersistPpm = 20.0
    /// Min ns between opportunistic saves (driveResampler's engaged branch).
    static let resamplerSkewSaveIntervalNanos: UInt64 = 60_000_000_000
    /// Quiet engaged ticks (4Hz) a save window needs before its mean integral
    /// persists: half the 60s window, so a mostly-held minute saves nothing.
    static let resamplerSkewMinQuietTicks = 120
    /// Integration hold (ns) after an event that isn't clock evidence: a (re-)prime
    /// arm, a cushion target move, or a trim (which clips only the high side, so
    /// while trims fire the integral may only speed playout up).
    static let resamplerEventHoldNanos: UInt64 = 10_000_000_000

    /// "" (no memory) when the host or the device is unknown.
    static func resamplerSkewKey(host: String, deviceUID: String?) -> String {
        guard host != "unknown", let deviceUID, !deviceUID.isEmpty else { return "" }
        return resamplerSkewKeyPrefix + host + "|" + deviceUID
    }

    /// Aged, clamped per-device skew seed, or 0 (no / stale / junk record). The
    /// clamp to `cushionReleaseSkewPpm` keeps a seed inside the converged
    /// envelope (stored values already are; this guards edited plists), so a
    /// seeded session never starts in the "railing" shallow-release lockout.
    static func loadResamplerSkewSeed(key: String, defaults: UserDefaults = .standard) -> Double {
        guard !key.isEmpty,
              let dict = defaults.dictionary(forKey: key),
              let ppm = dict["ppm"] as? Double, ppm.isFinite,
              let savedAt = dict["saved_at"] as? Double else { return 0 }
        let age = max(0, Date().timeIntervalSinceReferenceDate - savedAt)
        let aged = ppm * pow(0.5, age / resamplerSkewAgeHalfLifeSeconds)
        let clamped = max(-cushionReleaseSkewPpm, min(cushionReleaseSkewPpm, aged))
        return abs(clamped) >= resamplerSkewMinPersistPpm ? clamped : 0
    }

    /// Persist a converged skew under its host+device key. Callers gate on the
    /// converged envelope + the save window (driveResampler).
    static func persistResamplerSkew(key: String, ppm: Double, defaults: UserDefaults = .standard) {
        guard !key.isEmpty, ppm.isFinite else { return }
        defaults.set(
            ["ppm": ppm, "saved_at": Date().timeIntervalSinceReferenceDate],
            forKey: key)
    }

    /// The default output device changed mid-session: the integral now blends two
    /// device clocks, so it must not be saved under either key this session.
    func noteOutputDeviceLocked(uid: String?) {
        guard Self.resamplerSkewKey(host: cushionHostLabel, deviceUID: uid) != resamplerSkewMemoryKey
        else { return }
        resamplerSkewMemoryKey = ""
    }

    // MARK: - Drift-tracking resampler (deterministic clock-skew repayment)
    //
    //  MEASURED FAULT (a long wired 4K240 test): the audio clock
    //  drift gauge ramped at a rock-constant −39..−40.4µs/s in every quiet
    //  stretch, sawtoothing to −90..−140ms extremes; the post-learning
    //  under-runs each fired AT a sawtooth extreme, with spacing matching the
    //  drain math for a 40-80ms reservoir at 40ppm.
    //  A deterministic drain, not link noise - the cushion ladder can only
    //  stretch the period (deeper target → longer walk to empty), never fix
    //  it. The varispeed PI loop below
    //  (`driveResampler`) repays it: it steers the playout rate by ppm to absorb
    //  the standing host↔Mac clock offset so the cushion holds its depth instead
    //  of walking to empty. This replaced an earlier decode-path "5ms silence
    //  packet per 5ms of accrued skew" micro-stretch (AudioDecoder.swift notes
    //  the swap).

    /// Drift-tracking resampler PI loop. Called ~per decoded packet from
    /// `publishAudioState`; self-rate-limits to ~4Hz (drift is ppm-slow). When
    /// `engaged` (steady playout - `primed && !playoutDrained`) it steers the
    /// varispeed rate by the buffer-fill error: the INTEGRAL absorbs the steady
    /// host↔Mac clock offset (its whole job), the PROPORTIONAL answers transient
    /// fill excursions, both slew-limited so the rate (hence pitch) never steps
    /// audibly. When NOT engaged (pre-roll / re-prime / drain) it slews back to
    /// rate 1.0 but HOLDS the integral (the clock offset survives a drain). PI
    /// state is `audioMeterLock`-guarded (both publishAudioState callers).
    func driveResampler(fillMs: Double, targetMs: Double, engaged: Bool) {
        // PI state guarded by `audioMeterLock` (this runs from both publishAudioState
        // callers - decode path AND completion handler). Apply the computed rate
        // after unlocking, since applyVarispeedRate only enqueues onto its queue.
        audioMeterLock.lock()
        // Self-rate-limit to ~4Hz: publishAudioState fires per decoded packet
        // (~200Hz) and drift is ppm-slow, so a fast loop only adds noise.
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- lastResamplerUpdateNanos >= Self.resamplerUpdateIntervalNanos else {
            audioMeterLock.unlock(); return
        }
        lastResamplerUpdateNanos = now

        var rateToApply: Float?
        var skewSave: (key: String, ppm: Double)?
        if !engaged {
            // Pre-roll / re-prime / drain: slew the APPLIED rate to 1.0 (no pitch
            // step) but HOLD the integral - the host↔Mac clock offset survives a
            // drain, so re-engage with it already learned, not re-converged from 0.
            // The bleed waits for the FIRST engaged tick: a pre-roll must not
            // erode a persisted per-device skew seed the loop hasn't used yet.
            if resamplerEverEngaged {
                resamplerIntegralPpm *= Self.resamplerIntegralHoldFactor
            }
            if resamplerEpsPpm != 0 {
                resamplerEpsPpm += max(-Self.resamplerSlewPpm,
                                       min(Self.resamplerSlewPpm, -resamplerEpsPpm))
                rateToApply = Float(1.0 + resamplerEpsPpm * 1e-6)
            }
        } else {
            // Fill above the cushion setpoint ⇒ too much buffered ⇒ consume faster
            // (rate > 1). INTEGRAL absorbs the steady ppm offset; PROPORTIONAL answers
            // transient excursions; the deadband stops accrual on sub-ms noise.
            resamplerEverEngaged = true
            if targetMs != resamplerSetpointMs {
                resamplerSetpointMs = targetMs
                resamplerSetpointMovedNanos = now
            }
            let error = fillMs - targetMs
            let deadbanded = abs(error) < Self.resamplerDeadbandMs ? 0 : error
            let hold = Self.resamplerEventHoldNanos
            let frozen = now &- driftAnchorNanos < hold || now &- resamplerSetpointMovedNanos < hold
            let trimHeld = lastTrimNanos != 0 && now &- lastTrimNanos < hold
            var integralStep = frozen ? 0 : Self.resamplerKiPpmPerMs * deadbanded
            if trimHeld { integralStep = max(integralStep, 0) }
            resamplerIntegralPpm = clampResamplerPpm(resamplerIntegralPpm + integralStep)
            let targetPpm = clampResamplerPpm(
                Self.resamplerKpPpmPerMs * deadbanded + resamplerIntegralPpm)
            // Slew-limit the APPLIED offset so the rate (hence pitch) never steps.
            resamplerEpsPpm += max(-Self.resamplerSlewPpm,
                                   min(Self.resamplerSlewPpm, targetPpm - resamplerEpsPpm))
            rateToApply = Float(1.0 + resamplerEpsPpm * 1e-6)
            if !frozen && !trimHeld {
                resamplerQuietIntegralSumPpm += resamplerIntegralPpm
                resamplerQuietTicks += 1
            }
            skewSave = takeResamplerSkewSaveLocked(now: now)
        }
        audioMeterLock.unlock()
        if let rateToApply { applyVarispeedRate(rateToApply) }
        if let skewSave {
            Self.persistResamplerSkew(key: skewSave.key, ppm: skewSave.ppm)
        }
    }

    /// Close a save window (≥60s with enough quiet ticks) and return its MEAN quiet
    /// integral when it is inside the converged envelope and moved ≥5ppm: a snapshot
    /// can be mid-ring, the mean is the clock offset. Meter lock held.
    private func takeResamplerSkewSaveLocked(now: UInt64) -> (key: String, ppm: Double)? {
        guard !resamplerSkewMemoryKey.isEmpty,
              now &- lastResamplerSkewSaveNanos >= Self.resamplerSkewSaveIntervalNanos,
              resamplerQuietTicks >= Self.resamplerSkewMinQuietTicks else { return nil }
        let mean = resamplerQuietIntegralSumPpm / Double(resamplerQuietTicks)
        lastResamplerSkewSaveNanos = now
        resamplerQuietIntegralSumPpm = 0
        resamplerQuietTicks = 0
        let magnitude = abs(mean)
        guard magnitude >= Self.resamplerSkewMinPersistPpm,
              magnitude <= Self.cushionReleaseSkewPpm,
              !(abs(mean - lastSavedResamplerSkewPpm) < 5.0) else { return nil }
        lastSavedResamplerSkewPpm = mean
        return (resamplerSkewMemoryKey, mean)
    }

    private func clampResamplerPpm(_ ppm: Double) -> Double {
        max(-Self.resamplerBoundPpm, min(Self.resamplerBoundPpm, ppm))
    }

    /// Apply `varispeed.rate` OFF the player-node completion handler: writing it there
    /// (holding AVAudio's messenger lock) deadlocks against teardown's
    /// `playerNode.stop()` (engine lock). The hop breaks it; post-shutdown writes no-op.
    func applyVarispeedRate(_ rate: Float) {
        varispeedRateQueue.async { [weak self] in self?.varispeed.rate = rate }
    }
}
