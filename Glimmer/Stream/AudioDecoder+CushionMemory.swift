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

    /// COLD-SEED jitter coefficient. On a FRESH link (no per-host memory to
    /// adopt) the starting cushion is biased by `coldSeedJitterK * smoothedJitterMs`
    /// so a standing-jitter remote/VPN link starts near the depth it needs instead
    /// of blip-walking up from the bare base (the first-contact ratchet the per-host
    /// memory only papers over on the SECOND session). 2.0 ≈ 2σ of the jitter
    /// envelope. DO-NO-HARM (hard constraint): a clean/wired link's smoothed jitter
    /// is sub-ms, so the biased term stays well under `playoutCushionBaseMs` and the
    /// seed's `max(base, …)` returns the base UNCHANGED - byte-identical to the old
    /// fixed seed. Given the margin below, only standing jitter above ~10ms lifts it.
    static let coldSeedJitterK: Double = 2.0
    /// Fixed RTT-variance / scheduling-slack margin (ms) added to the jitter term in
    /// the cold seed. RTT variance isn't cheaply reachable from the reconciler's
    /// published decision (smoothed jitter is), so this stands in for it - one
    /// cushion step. Small enough that it never lifts a clean link off the base
    /// (the `max(base, …)` still picks the base when jitter is sub-ms).
    static let coldSeedRttVarMarginMs: Double = AudioDecoder.playoutCushionStepMs

    /// Jitter-aware COLD seed (ms) for a fresh link with NO per-host memory to
    /// adopt: bias the starting cushion off the reconciler's live smoothed jitter
    /// so a standing-jitter link doesn't blip-walk up from the bare base. Pure read
    /// of `EnvSignalController`'s published decision; touches no control flow, no
    /// grow/decay/floor, no steady-state.
    ///
    /// DO-NO-HARM: a clean/wired link's smoothed jitter is sub-ms, so
    /// `k*jitter + margin` stays under `base` and `max(base, …)` returns `base`
    /// UNCHANGED - byte-identical to the old fixed 30ms seed. A cold/zero estimate
    /// (pre-roll before the reconciler has data) returns `base` via the `jitter > 0`
    /// guard. The result is clamped to `cap` so it can never seed past the over-run
    /// envelope. Callers only reach this on the no-memory path (memory still wins).
    static func jitterAwareColdSeedMs(base: Double, cap: Double) -> Double {
        let jitter = EnvSignalController.shared.decision.smoothedJitterMs
        guard jitter.isFinite, jitter > 0 else { return base }
        let biased = (coldSeedJitterK * jitter).rounded(.up) + coldSeedRttVarMarginMs
        return min(max(base, biased), cap)
    }

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
    /// Adaptive-cushion cap (ms) for a clean WI-FI link - between wired 150ms and
    /// tunnel 300ms. Wi-Fi's gap envelope (contention, power-save) is deeper than
    /// wired but nowhere near a tunnel's, so the 300ms cap let the ratchet pin it
    /// far deeper than needed. 200ms covers Wi-Fi gaps; still keyed and decaying.
    static let playoutCushionMaxMsWifi: Double = 200
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
        switch link {
        case "wired": return playoutCushionMaxMs
        case "wifi": return playoutCushionMaxMsWifi
        default: return playoutCushionMaxMsTunnel
        }
    }

    /// Half-life (s) of a persisted record's AGE LERP toward base: an unrefreshed
    /// target/floor lerps halfway back every ~6h. A link's loss character drifts
    /// (moved rooms, a one-off bad night), so a stale deep record shouldn't seed
    /// full-depth forever - it re-learns its own depth each session anyway.
    static let cushionMemoryAgeHalfLifeSeconds: Double = 6 * 3600

    /// The cap (ms) a link-keyed record may seed at: its OWN learned class's cap,
    /// so a tunnel-depth never seeds a clean wired link. Unknown-keyed records
    /// (telemetry-off bring-up) fail toward the deeper tunnel cap.
    private static func recordSeedCapMs(forLink link: String) -> Double {
        link == "unknown" ? playoutCushionMaxMsTunnel : cushionMaxMs(forLink: link)
    }

    /// Read one persisted record, AGE-LERPed toward base and clamped to its own
    /// link-class cap (the link rides the key). Defensive against hand-edits.
    static func readCushionMemory(key: String) -> (targetMs: Double, floorMs: Double)? {
        guard let dict = UserDefaults.standard.dictionary(forKey: key),
              let target = dict["target_ms"] as? Double, target.isFinite else { return nil }
        var floor = (dict["floor_ms"] as? Double).flatMap { $0.isFinite ? $0 : nil } ?? 0
        // AGE LERP: pull a stale target/floor toward base by its wall age (the
        // link's loss character drifts; a record re-learns its own depth anyway).
        var agedTarget = target
        if let saved = dict["saved_at"] as? Double, saved > 0 {
            let ageSeconds = Date().timeIntervalSinceReferenceDate - saved
            if ageSeconds > 0 {
                let keep = pow(0.5, ageSeconds / cushionMemoryAgeHalfLifeSeconds)
                agedTarget = playoutCushionBaseMs + (target - playoutCushionBaseMs) * keep
                floor *= keep
            }
        }
        // Clamp to the record's OWN link-class cap (parsed from the key) so a
        // tunnel-learned depth can never seed a clean wired link.
        let link = key.split(separator: "|").last.map(String.init) ?? "unknown"
        let cap = recordSeedCapMs(forLink: link)
        let clampedTarget = min(max(agedTarget, playoutCushionBaseMs), cap)
        // WELD REPAIR: a floor at/above the cap (or at/above the target) is a
        // poisoned record - skew under-runs welded the floor to the cap and froze
        // the target one step above it. Drop the floor to base so the session
        // re-learns from a healthy floor instead of re-seeding into the lock.
        if floor >= cap || floor >= clampedTarget {
            floor = min(playoutCushionBaseMs, clampedTarget)
        }
        return (clampedTarget, min(max(floor, 0), clampedTarget))
    }

    /// Write-through on every learn/decay edge (rare: at most ~1/min decay,
    /// per-under-run grow), so a crash or force-quit never loses the session's
    /// learning. A mid-spike write self-corrects: each later decay step
    /// persists the lower value, and a seeded spike decays normally next run.
    static func persistCushionMemory(key: String, targetMs: Double, floorMs: Double) {
        guard !key.isEmpty else { return }
        // `saved_at` (wall reference seconds) drives the read-side age lerp - a
        // record refreshed this session reads near full depth, a stale one decays.
        UserDefaults.standard.set(
            ["target_ms": targetMs, "floor_ms": floorMs,
             "saved_at": Date().timeIntervalSinceReferenceDate],
            forKey: key)
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
        // No memory for this host+link. Bias the cold seed off the live link
        // estimate (jitter-aware); a clean link reads the base unchanged. At INIT
        // the reconciler usually has no jitter yet (link still "unknown"), so this
        // typically resolves to the base here and actually bites at the one-shot
        // link resolve (resolveCushionLink) ~1-2s later, where jitter is meaningful.
        return CushionSeed(key: key, host: host, link: link,
                           targetMs: jitterAwareColdSeedMs(
                               base: playoutCushionBaseMs, cap: cushionMaxMs(forLink: link)),
                           floorMs: 0, fromMemory: false)
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
                // WIRED RELEASE: on a quiet, healthy resolved-wired link, walk the
                // floor DOWN one step in step with the target instead of waiting on
                // the ~10min floor clock (skew under-runs keep re-arming it, so it
                // never releases). Same quiet window + near-miss evidence the target
                // decay uses; wifi/tunnel/unknown keep the slow clock untouched.
                if EnvSignalController.shared.streamLink == "wired" {
                    learnedFloorMs = max(learnedFloorMs - Self.playoutCushionStepMs,
                                         Self.playoutCushionBaseMs)
                    playoutTargetMs = max(candidate, Self.playoutCushionBaseMs)
                    floorQuietSinceNanos = now
                    quietSinceNanos = now
                    quietWindowMinFillMs = .infinity
                    changed = true
                }
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
            // Set the link-aware cap from whatever the route reads NOW so a
            // late/never resolve can't freeze at the tunnel-300 default (only
            // ever equals-or-lowers the cap; pure field write under the lock).
            effectiveCushionMaxMs = Self.cushionMaxMs(forLink: EnvSignalController.shared.streamLink)
            effectiveOverrunCeilingMs = effectiveCushionMaxMs + Self.bufferOverrunCeilingSlackMs
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
        // Jitter-aware cold seed for the no-memory branch below - computed HERE,
        // OUTSIDE the meter lock (it reads EnvSignal's own lock; the tiny-lock
        // discipline this file keeps). By now (~1-2s in) the reconciler HAS jitter,
        // unlike at the init seed, so this is where the cold seed actually bites.
        // Clean link → base (do-no-harm).
        let coldSeedMs = Self.jitterAwareColdSeedMs(
            base: Self.playoutCushionBaseMs, cap: Self.cushionMaxMs(forLink: link))

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
        var coldSeedApplied = false
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
            // session: seed off the now-meaningful live jitter (cold seed) rather
            // than dropping flat to base, so a standing-jitter link starts near the
            // depth it needs. The borrowed bring-up guess is still discarded - we
            // seed from THIS link's OWN measured jitter, not the borrow, so a
            // wrong-link seed can't persist into this bucket. DO-NO-HARM: a clean
            // link's coldSeedMs == base, byte-identical to the old `= base`. The
            // ladder still re-learns this link from its own evidence on top.
            playoutTargetMs = coldSeedMs
            learnedFloorMs = 0
            coldSeedApplied = true
            quietSinceNanos = now
            floorQuietSinceNanos = now
            quietWindowMinFillMs = .infinity
        }
        // CLAMP to the now-resolved cap on EVERY path: the seed defaulted deep
        // (tunnel cap / borrowed record during the unknown window), so a link
        // resolving wired/wifi tightens target + floor to the real cap at once,
        // not walking down through the trim. The grow ratchet re-earns real depth.
        playoutTargetMs = max(Self.playoutCushionBaseMs,
                              min(playoutTargetMs, effectiveCushionMaxMs))
        learnedFloorMs = min(learnedFloorMs, effectiveCushionMaxMs)
        let target = playoutTargetMs
        let floor = learnedFloorMs
        let cap = effectiveCushionMaxMs
        audioMeterLock.unlock()
        AudioCushionTelemetry.shared.setFloorMs(floor)
        Diag.notice(
            "audio cushion link resolved: \(link) - target \(Int(target.rounded()))ms "
            + "floor \(Int(floor.rounded()))ms"
            + (stored != nil ? " (per-host memory adopted)" : " (no memory for this link yet)"),
            "Stream")
        // Cold-seed breadcrumb: greppable record of the jitter-aware decision when
        // it actually lifted the seed above base on this fresh link. Updates the
        // seed gauge to the resolve-time value (the init latch held the base).
        if coldSeedApplied {
            AudioCushionTelemetry.shared.setSeedMs(target)
            if target > Self.playoutCushionBaseMs {
                Diag.notice(
                    "audio cushion cold-seed (jitter-aware): \(Int(target.rounded()))ms from "
                    + "smoothed jitter "
                    + "\(String(format: "%.1f", EnvSignalController.shared.decision.smoothedJitterMs))ms "
                    + "(base \(Int(Self.playoutCushionBaseMs))ms, cap \(Int(cap))ms) - link \(link)",
                    "Audio")
            }
        }
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
    /// rate 1.0 but HOLDS the integral (the clock offset survives a drain). Single
    /// caller, so the resampler state needs no lock.
    func driveResampler(fillMs: Double, targetMs: Double, engaged: Bool) {
        // Self-rate-limit to ~4Hz: publishAudioState fires per decoded packet
        // (~200Hz) and drift is ppm-slow, so a fast loop only adds noise.
        let now = DispatchTime.now().uptimeNanoseconds
        guard now &- lastResamplerUpdateNanos >= Self.resamplerUpdateIntervalNanos else { return }
        lastResamplerUpdateNanos = now

        guard engaged else {
            // Pre-roll / re-prime / drain: slew the APPLIED rate to 1.0 (no pitch
            // step) but HOLD the integral - the host↔Mac clock offset survives a
            // drain, so re-engage with it already learned, not re-converged from 0.
            // The ×0.97 bleed only runs while packets flow (an active re-prime); a
            // true silence stops calling this, so it can't bleed a real offset away.
            resamplerIntegralPpm *= Self.resamplerIntegralHoldFactor
            if resamplerEpsPpm != 0 {
                resamplerEpsPpm += max(-Self.resamplerSlewPpm,
                                       min(Self.resamplerSlewPpm, -resamplerEpsPpm))
                applyVarispeedRate(Float(1.0 + resamplerEpsPpm * 1e-6))
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
        applyVarispeedRate(Float(1.0 + resamplerEpsPpm * 1e-6))
    }

    private func clampResamplerPpm(_ v: Double) -> Double {
        max(-Self.resamplerBoundPpm, min(Self.resamplerBoundPpm, v))
    }

    /// Apply `varispeed.rate` OFF the player-node completion handler: writing it there
    /// (holding AVAudio's messenger lock) deadlocks against teardown's
    /// `playerNode.stop()` (engine lock). The hop breaks it; post-shutdown writes no-op.
    func applyVarispeedRate(_ rate: Float) {
        varispeedRateQueue.async { [weak self] in self?.varispeed.rate = rate }
    }
}
