//
//  AudioDecoder+CushionMemory.swift
//
//  The cushion LOSS FLOOR + per-host memory - the decay-limit-cycle fix.
//
//  MEASURED FAULT (extended wifi testing): the 60s-quiet decay stepped the
//  target down INTO the link's ambient loss floor, under-ran, re-ratcheted -
//  an audible blip every ~90s of clean play, the under-runs landing at targets
//  the ladder had just walked down from the link's ~80ms equilibrium. A slow
//  limit cycle: the exact disguised-oscillation the decay was meant to avoid,
//  one octave down. Plus several startup blips per session on both links while
//  the ratchet re-derived what the previous session already knew.
//
//  THREE LAYERS, all evidence-keyed, all recovering (no permanent give-ups):
//   (1) NEAR-MISS GATE - a decay step requires the quiet window's MIN fill to
//       have stayed a full step above empty. A trough that came within one
//       step of empty is the same starvation evidence as an under-run, minus
//       the audible event - it holds depth WITHOUT the user paying a blip.
//   (2) LOSS FLOOR - an EWMA of the target at each under-run learns the level
//       this link actually fails at; the decay never steps below floor + one
//       step without the floor itself decaying first. JITTERY-LINK ARGUMENT:
//       the floor adapts BOTH ways - fresh under-runs pull it up immediately
//       (evidence-weighted), and a slow ~10min quiet clock walks it down, so
//       a genuinely improved link re-earns shallow cushions while a link that
//       keeps proving its losses keeps its depth. Even a floor learned at the
//       cap self-heals: each 10min clean window lowers it a step, unblocking
//       the target decay - blocked states always have a clock running.
//   (3) PER-HOST MEMORY - the learned target + floor persist in UserDefaults
//       keyed "host|link" and SEED the
//       next session, so the cold pre-roll builds the depth this host+link
//       needs instead of re-paying the first-minutes ratchet walk. The link
//       is usually unknown at audio bring-up (the route probe feeds ~1-2s
//       later), so the seed starts from the best available record and a
//       one-shot resolve re-keys it when the route lands; if it never lands
//       (telemetry off), learning continues under the init key - the
//       "host|unknown" bucket converges by the same machinery, just unsplit.
//
//  Decay ABOVE the floor is untouched: transient distress spikes still come
//  back down at the same ~10ms/min. Zero host changes; everything here is
//  client-side playout depth policy.
//
//  ALSO HERE (it guards the same cushion): the DRIFT MICRO-STRETCH - the
//  deterministic clock-skew repayment. See its own section below for the
//  measured fault and the jittery-link argument.
//

import AVFoundation
import Foundation

extension AudioDecoder {

    // MARK: - Tunables

    /// Quiet window (ns) with ZERO under-runs required per one-step DECAY of the
    /// adaptive cushion back toward the base. Deliberately asymmetric against the
    /// grow path (grow: one step per real under-run; decay: ~60 clean seconds per
    /// step) so the target can't oscillate on a jittery link - recurring gaps hold
    /// the depth, while a genuinely calm link walks back down at ~10ms/min.
    /// The step is additionally gated on the window's MIN fill (near-miss
    /// evidence) and on the learned loss floor - the measured 90s decay→
    /// under-run→re-ratchet limit cycle this file exists to kill.
    static let playoutDecayQuietNanos: UInt64 = 60_000_000_000
    /// EWMA weight pulling the loss floor toward the target that just FAILED.
    /// 0.5 converges in 2-3 under-runs (the measured failure targets cluster
    /// within 2 steps) without letting a single outlier own the floor.
    static let cushionFloorEwmaWeight: Double = 0.5
    /// Quiet window (ns) per one-step decay of the FLOOR itself (~10min). The
    /// slow clock that lets an improved link re-earn shallow cushions - and
    /// the liveness guarantee for every floor-blocked decay.
    static let cushionFloorDecayQuietNanos: UInt64 = 600_000_000_000
    /// Near-miss margin (ms): the decay window's MIN fill must clear this
    /// (one full step above empty) before a step down is allowed - a window
    /// that nearly drained proves the NEXT step down would under-run.
    static let cushionNearMissMarginMs: Double = AudioDecoder.playoutCushionStepMs
    /// Window (ns) the one-shot link resolve keeps trying after init before
    /// settling on the init key (the exporter feeds the route within ~2s when
    /// telemetry is on; 120s covers a slow bring-up with margin).
    static let cushionLinkResolveWindowNanos: UInt64 = 120_000_000_000
    /// UserDefaults key prefix; full key = prefix + "host|link". Local-only
    /// preference storage - the host never rides telemetry or logs.
    static let cushionMemoryKeyPrefix = "audioCushionMemory."

    // MARK: - Persistence (UserDefaults, per host+link)

    /// One session's starting cushion, resolved at decoder init.
    struct CushionSeed {
        let key: String
        let host: String
        let link: String
        let targetMs: Double
        let floorMs: Double
        let fromMemory: Bool
        var linkKnown: Bool { link != "unknown" }
    }

    /// A pending memory write captured under the meter lock, committed off it.
    struct CushionMemoryWrite {
        let key: String
        let targetMs: Double
        let floorMs: Double
    }

    static func cushionMemoryKey(host: String, link: String) -> String {
        "\(cushionMemoryKeyPrefix)\(host)|\(link)"
    }

    /// Adaptive-cushion cap (ms) for a WIFI/TUNNEL link - the runtime cap when
    /// `EnvSignalController.streamLink` is one of those. 300ms is deep enough that
    /// the grow ratchet can reach the depth a VPN's multi-hundred-ms gaps need
    /// instead of hard-stopping below it (the wired 150ms cap, `playoutCushionMaxMs`,
    /// is below that envelope). Still bounded (worst-case standing latency,
    /// trimmed/decayed back once gaps stop).
    static let playoutCushionMaxMsTunnel: Double = 300
    /// Slack (ms) the OVER-RUN ceiling sits ABOVE the active cushion cap so a
    /// max-deepened cushion can PRE-ROLL + absorb its post-gap catch-up clump
    /// without tripping the backstop. The runtime ceiling (`effectiveOverrunCeilingMs`)
    /// tracks the link-aware cap: wired 150+40=190ms, tunnel/wifi 300+40=340ms.
    static let bufferOverrunCeilingSlackMs: Double = 40
    /// Over-run ceiling (ms) for STATIC-context callers (telemetry export); the
    /// runtime gate uses `effectiveOverrunCeilingMs`. The dogshit-link BACKSTOP,
    /// not the steady-state governor - that is TRIM-TOWARD-TARGET
    /// (`meterRegisterScheduleOrOverrun`). Sized to the deepest (tunnel) cap +
    /// slack so even that fits: 300+40=340ms.
    static let bufferOverrunCeilingMs: Double =
        playoutCushionMaxMsTunnel + bufferOverrunCeilingSlackMs

    /// LINK-AWARE cushion cap (ms) for a resolved stream-link class. A wired NIC's
    /// delivery-gap envelope fits the 150ms wired cap; a wifi/tunnel link's is
    /// deeper, so it gets the 300ms cap. Unknown fails toward the deeper cap (same
    /// deep-by-default bring-up policy as the seed - too shallow glitches, too deep
    /// walks down through the trim).
    static func cushionMaxMs(forLink link: String) -> Double {
        link == "wired" ? playoutCushionMaxMs : playoutCushionMaxMsTunnel
    }

    /// Read one persisted record, clamped defensively (a hand-edited or
    /// corrupt default must not seed outside the ladder's own bounds).
    static func readCushionMemory(key: String) -> (targetMs: Double, floorMs: Double)? {
        guard let dict = UserDefaults.standard.dictionary(forKey: key),
              let target = dict["target_ms"] as? Double, target.isFinite else { return nil }
        // Clamp to the DEEPEST (tunnel) cap at load: a tunnel session legitimately
        // learns up to 300ms, and clamping that to the wired 150ms here would lose
        // it on reload. The runtime link-aware cap (`effectiveCushionMaxMs`) then
        // governs - a wired session seeded deep walks back down through the trim.
        let clampedTarget = min(max(target, playoutCushionBaseMs), playoutCushionMaxMsTunnel)
        let floor = (dict["floor_ms"] as? Double).flatMap { $0.isFinite ? $0 : nil } ?? 0
        return (clampedTarget, min(max(floor, 0), clampedTarget))
    }

    /// Write-through on every learn/decay edge (rare: at most ~1/min decay,
    /// per-under-run grow), so a crash or force-quit never loses the session's
    /// learning. A mid-spike write self-corrects: each later decay step
    /// persists the lower value, and a seeded spike decays normally next run.
    static func persistCushionMemory(key: String, targetMs: Double, floorMs: Double) {
        guard !key.isEmpty else { return }
        UserDefaults.standard.set(["target_ms": targetMs, "floor_ms": floorMs], forKey: key)
    }

    /// Resolve this session's seed: the init key's own record first; when the
    /// link is still unknown, BORROW the deepest of the link-split records
    /// (deep-by-default fails toward a few ms of extra audio latency that the
    /// trim walks off in ~1s once the link resolves shallow - the alternative,
    /// shallow-by-default, fails toward audible blips).
    static func loadCushionSeed() -> CushionSeed {
        let host = StreamRouteProbe.currentLatchedHost ?? "unknown"
        let link = EnvSignalController.shared.streamLink
        let key = cushionMemoryKey(host: host, link: link)
        if let record = readCushionMemory(key: key) {
            return CushionSeed(key: key, host: host, link: link,
                               targetMs: record.targetMs, floorMs: record.floorMs,
                               fromMemory: true)
        }
        if link == "unknown" {
            let borrowed = ["wifi", "wired"]
                .compactMap { readCushionMemory(key: cushionMemoryKey(host: host, link: $0)) }
                .max { $0.targetMs < $1.targetMs }
            if let borrowed {
                return CushionSeed(key: key, host: host, link: link,
                                   targetMs: borrowed.targetMs, floorMs: borrowed.floorMs,
                                   fromMemory: true)
            }
        }
        return CushionSeed(key: key, host: host, link: link,
                           targetMs: playoutCushionBaseMs, floorMs: 0, fromMemory: false)
    }

    /// Announce the seed (sensor-honesty: a new dial self-describes) and latch
    /// it for the `audio_ttf` event + the 1Hz floor gauge. Secret-free: the
    /// LINK rides the line, the host half of the key never leaves UserDefaults.
    func announceCushionSeed(_ seed: CushionSeed) {
        AudioCushionTelemetry.shared.latchSeed(AudioCushionTelemetry.Seed(
            link: seed.link, targetMs: seed.targetMs, floorMs: seed.floorMs,
            fromMemory: seed.fromMemory))
        Diag.notice(
            "audio cushion seed: target \(Int(seed.targetMs.rounded()))ms floor "
            + "\(Int(seed.floorMs.rounded()))ms - link \(seed.link), "
            + (seed.fromMemory ? "from per-host memory" : "defaults (no memory yet)"),
            "Stream")
    }

    // MARK: - Meter-side adjustments (audioMeterLock HELD by the caller)

    /// UNDER-RUN edge: learn the floor from the target that just FAILED (the
    /// pre-grow level) and restart both quiet clocks. Returns the memory write
    /// for the caller to commit off the lock.
    func cushionNoteUnderrunLocked(now: UInt64, failedTargetMs: Double) -> CushionMemoryWrite {
        cushionHadUnderrun = true
        learnedFloorMs = learnedFloorMs <= 0
            ? failedTargetMs
            : learnedFloorMs + Self.cushionFloorEwmaWeight * (failedTargetMs - learnedFloorMs)
        learnedFloorMs = min(learnedFloorMs, effectiveCushionMaxMs)
        floorQuietSinceNanos = now
        quietWindowMinFillMs = .infinity
        return CushionMemoryWrite(key: cushionSeedKey, targetMs: playoutTargetMs,
                                  floorMs: learnedFloorMs)
    }

    /// QUIET completion while elevated: arbitrate the two decay clocks.
    /// Floor decay first (the slow ~10min clock), then the target step gated
    /// on (a) the elapsed quiet window, (b) the near-miss margin - a held
    /// window consumes its evidence and starts a fresh one - and (c) the
    /// floor cutoff, which leaves the window STANDING so the step fires the
    /// moment the floor's own decay unblocks it. Returns a memory write when
    /// anything moved; nil on the (overwhelmingly common) no-op.
    func cushionQuietAdjustLocked(now: UInt64) -> CushionMemoryWrite? {
        var changed = false
        if learnedFloorMs > 0,
           now &- floorQuietSinceNanos >= Self.cushionFloorDecayQuietNanos {
            learnedFloorMs = max(learnedFloorMs - Self.playoutCushionStepMs, 0)
            floorQuietSinceNanos = now
            changed = true
        }
        if now &- quietSinceNanos >= Self.playoutDecayQuietNanos {
            let candidate = playoutTargetMs - Self.playoutCushionStepMs
            if quietWindowMinFillMs < Self.cushionNearMissMarginMs {
                // NEAR-MISS HOLD: the window's trough proved the next step
                // would starve - keep depth, pay nothing audible.
                quietSinceNanos = now
                quietWindowMinFillMs = .infinity
            } else if learnedFloorMs > 0,
                      candidate < learnedFloorMs + Self.playoutCushionStepMs {
                // FLOOR HOLD: below floor+step needs the floor to decay first.
            } else {
                playoutTargetMs = max(candidate, Self.playoutCushionBaseMs)
                quietSinceNanos = now
                quietWindowMinFillMs = .infinity
                changed = true
            }
        }
        guard changed else { return nil }
        return CushionMemoryWrite(key: cushionSeedKey, targetMs: playoutTargetMs,
                                  floorMs: learnedFloorMs)
    }

    /// Commit a captured write OUTSIDE the meter lock: UserDefaults (its own
    /// lock; never nested under the meter's) + the 1Hz floor gauge.
    func commitCushionMemory(_ write: CushionMemoryWrite) {
        Self.persistCushionMemory(key: write.key, targetMs: write.targetMs, floorMs: write.floorMs)
        AudioCushionTelemetry.shared.setFloorMs(write.floorMs)
    }

    // MARK: - One-shot link resolve (the seed re-key)

    /// Re-key the cushion memory once the stream link is actually known. The
    /// route probe feeds EnvSignal ~1-2s after the exporter starts - long
    /// after the audio pre-roll primed on the init seed - so this swaps the
    /// MEMORY (and adopts the resolved link's record) without touching the
    /// standing fill: an upgrade materializes at the next re-prime (≤1 blip,
    /// the verification bar), a downgrade walks off through the trim. Called
    /// from `publishAudioState` only while unresolved; expires after the
    /// resolve window so the steady-state cost returns to one Bool read.
    func resolveCushionLink() {
        let now = DispatchTime.now().uptimeNanoseconds
        audioMeterLock.lock()
        guard !cushionLinkResolved else { audioMeterLock.unlock(); return }
        if now >= cushionLinkResolveDeadlineNanos {
            // Window over (telemetry off / probe dark): settle on the init
            // key. Not a give-up - learning continues, and the floor's slow
            // decay still walks any borrowed depth down if it was too deep.
            cushionLinkResolved = true
            audioMeterLock.unlock()
            return
        }
        let host = cushionHostLabel
        audioMeterLock.unlock()
        let link = EnvSignalController.shared.streamLink
        guard link != "unknown" else { return }
        // UserDefaults read OUTSIDE the meter lock (CFPrefs can block on IPC;
        // the tiny-lock discipline stands even on this one-shot path).
        let key = Self.cushionMemoryKey(host: host, link: link)
        let stored = Self.readCushionMemory(key: key)

        audioMeterLock.lock()
        // Re-check after the lock gap: the decode and completion threads both
        // publish state, so two resolves can race here - first one wins.
        guard !cushionLinkResolved else { audioMeterLock.unlock(); return }
        cushionLinkResolved = true
        cushionSeedKey = key
        // Refresh the LINK-AWARE caps now the route is real (the init seed defaulted
        // to the deeper tunnel cap; a resolved-wired link tightens it back to 150ms).
        effectiveCushionMaxMs = Self.cushionMaxMs(forLink: link)
        effectiveOverrunCeilingMs = effectiveCushionMaxMs + Self.bufferOverrunCeilingSlackMs
        if let stored {
            if cushionHadUnderrun {
                // This session already produced real evidence: the resolved
                // record may only DEEPEN it, never erase it.
                playoutTargetMs = max(playoutTargetMs, stored.targetMs)
                learnedFloorMs = max(learnedFloorMs, stored.floorMs)
            } else {
                playoutTargetMs = stored.targetMs
                learnedFloorMs = stored.floorMs
            }
            quietSinceNanos = now
            floorQuietSinceNanos = now
            quietWindowMinFillMs = .infinity
        } else if !cushionHadUnderrun {
            // No memory for the RESOLVED link and no real evidence yet this
            // session: drop the borrowed bring-up guess back to defaults so a
            // wrong-link seed can't persist into this link's bucket - the
            // ladder re-learns this link from its own evidence (one blip
            // worst-case re-arms the floor immediately).
            playoutTargetMs = Self.playoutCushionBaseMs
            learnedFloorMs = 0
            quietSinceNanos = now
            floorQuietSinceNanos = now
            quietWindowMinFillMs = .infinity
        }
        let target = playoutTargetMs
        let floor = learnedFloorMs
        audioMeterLock.unlock()
        AudioCushionTelemetry.shared.setFloorMs(floor)
        Diag.notice(
            "audio cushion link resolved: \(link) - target \(Int(target.rounded()))ms "
            + "floor \(Int(floor.rounded()))ms"
            + (stored != nil ? " (per-host memory adopted)" : " (no memory for this link yet)"),
            "Stream")
    }

    // MARK: - Drift micro-stretch (deterministic clock-skew repayment)
    //
    //  MEASURED FAULT (a long wired 4K240 test): the audio clock
    //  drift gauge ramped at a rock-constant −39..−40.4µs/s in every quiet
    //  stretch, sawtoothing to −90..−140ms extremes; the post-learning
    //  under-runs each fired AT a sawtooth extreme, with spacing matching the
    //  drain math for a 40-80ms reservoir at 40ppm.
    //  A deterministic drain, not link noise - the cushion ladder can only
    //  stretch the period (deeper target → longer walk to empty), never fix
    //  it. The repayment: once the LONG-WINDOW accumulated drift proves a
    //  standing skew, insert one 5ms silence packet per 5ms of accrued skew
    //  (~40µs/s at the measured 40ppm - one packet per ~2min, inaudible) so
    //  the cushion holds its depth instead of walking to empty. Discrete
    //  packet quanta in the trim machinery's idiom - threshold-armed,
    //  rate-limited, standing down in distress windows - NOT a resampler:
    //  no signal-path rework, no decoder state touched, and the cadence the
    //  steady-state trim already proved inaudible bounds this too.
    //
    //  JITTERY-LINK ARGUMENT (why this can't oscillate on a bursty link): the
    //  key is the CUMULATIVE per-segment drift - an integral needing many
    //  minutes of one-sided ppm-scale accrual to reach the arm point - never
    //  a short-window slope. Delivery jitter can only push that gauge
    //  POSITIVE (a late clump stalls `framesScheduled` while wall time runs;
    //  media the host hasn't sent cannot arrive early), so burst wobble moves
    //  the residual AWAY from the arm point - and the threshold is 6× the
    //  5ms single-packet granularity besides. Corroboration gate: a stretch
    //  also requires the fill to actually sit a full step short of target, so
    //  a gauge gone haywire against a healthy cushion does nothing. And every
    //  distress window disarms it outright - un-primed, drained, and the
    //  post-(re)prime grace belong to the under-run/rebuild machinery, which
    //  keeps sole custody of recovery there.

    /// Drift-tracking resampler PI loop. Called ~per decoded packet from
    /// `publishAudioState`; self-rate-limits to ~4Hz (drift is ppm-slow). When
    /// `engaged` (steady playout - `primed && !playoutDrained`) it steers the
    /// varispeed rate by the buffer-fill error: the INTEGRAL absorbs the steady
    /// host↔Mac clock offset (its whole job), the PROPORTIONAL answers transient
    /// fill excursions, both slew-limited so the rate (hence pitch) never steps
    /// audibly. When NOT engaged (pre-roll / re-prime / drain) it forgets the
    /// estimate and slews back to rate 1.0 so a resumed segment starts neutral -
    /// the under-run + rebuild machinery owns recovery there. Single caller, so the
    /// resampler state needs no lock.
    func driveResampler(fillMs: Double, targetMs: Double, engaged: Bool) {
        // Self-rate-limit to ~4Hz: publishAudioState fires per decoded packet
        // (~200Hz) and drift is ppm-slow, so a fast loop only adds noise.
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- lastResamplerUpdateNanos >= Self.resamplerUpdateIntervalNanos else { return }
        lastResamplerUpdateNanos = now

        guard engaged else {
            // Pre-roll / re-prime / drain: the under-run + rebuild machinery owns
            // recovery. Forget the drift estimate and slew the rate back to 1.0 so
            // a resumed segment starts neutral. (Slew, never snap - no pitch step.)
            resamplerIntegralPpm = 0
            if resamplerEpsPpm != 0 {
                resamplerEpsPpm += max(-Self.resamplerSlewPpm,
                                       min(Self.resamplerSlewPpm, -resamplerEpsPpm))
                varispeed.rate = Float(1.0 + resamplerEpsPpm * 1e-6)
            }
            return
        }
        // Fill above the cushion setpoint ⇒ too much buffered ⇒ consume faster
        // (rate > 1). The INTEGRAL absorbs the steady ppm clock offset (its whole
        // job); the PROPORTIONAL term answers transient fill excursions. The
        // deadband stops the integral accruing on sub-ms noise once converged.
        let error = fillMs - targetMs
        let e = abs(error) < Self.resamplerDeadbandMs ? 0 : error
        resamplerIntegralPpm = clampResamplerPpm(resamplerIntegralPpm + Self.resamplerKiPpmPerMs * e)
        let targetPpm = clampResamplerPpm(Self.resamplerKpPpmPerMs * e + resamplerIntegralPpm)
        // Slew-limit the APPLIED offset so the rate (hence pitch) never steps.
        resamplerEpsPpm += max(-Self.resamplerSlewPpm,
                               min(Self.resamplerSlewPpm, targetPpm - resamplerEpsPpm))
        varispeed.rate = Float(1.0 + resamplerEpsPpm * 1e-6)
    }

    private func clampResamplerPpm(_ v: Double) -> Double {
        max(-Self.resamplerBoundPpm, min(Self.resamplerBoundPpm, v))
    }
}
