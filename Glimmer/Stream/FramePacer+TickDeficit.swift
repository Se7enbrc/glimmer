//
//  FramePacer+TickDeficit.swift
//
//  The tick-deficit DEGRADED MODE - the failsafe for the macOS frame-rate
//  governor throttling CADisplayLink callbacks below the pinned
//  preferredFrameRateRange floor (the floor is ADVISORY; on battery + the
//  built-in ProMotion panel it is demonstrably ignored). All four hard stalls
//  of one battery wifi run were this mechanism: ticks collapsed
//  120→10-58/s while frames kept arriving at 110-120fps with the radio provably
//  clean (zero net gaps >100ms all session, RSSI/txRate flat through every
//  freeze), so the tick-slaved pacer froze the screen and machine-gunned the
//  depth-6 queue into drops_presentation_late at up to 110/s.
//
//  The failsafe keys on the ACTUAL fault, MEASURED - never inferred: a rolling
//  ~250ms window over the pacer's own tick/release counters yields the realized
//  tick rate, compared against min(stream Hz, NOMINAL panel Hz). When ticks sag
//  below half of that for a full window with frames queued, an off-tick release
//  timer on the pacing queue takes over releasing due frames at stream cadence
//  (in-session proof this is the right shape: one collapse's giveup ran a
//  direct-present phase at renders==received, 0 late drops, o2p median 2.63ms
//  vs 9-13ms paced). It also re-commits the current frame when nothing new
//  flows, so the governor never classifies the layer as static - the suspected
//  spiral that locks a collapse in (commits stop → governor holds the low
//  rate). The mode disengages on its own the moment measured ticks recover
//  (hysteresis: enter <0.5×, exit ≥0.8× expected) - dynamic, condition-keyed,
//  self-recovering, never a one-way latch.
//
//  JITTERY-LINK SAFETY (the watchdog's regression history is the cautionary
//  tale): the trigger is a pure DISPLAY-side signal - realized CADisplayLink
//  callback rate - which network jitter cannot move. Zero-loss wifi jitter
//  pins the FIFO and late-drops while ticks stay at panel rate (~120/s ≥ 0.8×
//  expected), so the mode can never engage on a jittery-but-ticking link. The
//  expected rate is clamped to the NOMINAL panel Hz (which keeps reading the
//  rated cadence even while callbacks are throttled - verified
//  refresh_changed=0 through every collapse), so fps>refresh setups (120fps on
//  a 60Hz panel, ticks legitimately half the stream rate) and the wired 240Hz
//  panel's 119.996Hz divisor-decimation seconds (~0.71× expected) never read
//  as a deficit. Suppressed presentation (window hidden → link stops BY
//  DESIGN) is excluded explicitly.
//
//  This file also owns the WARM HANDOVER for pacer re-enable (the cold cutover
//  onto an un-primed link re-froze the stream 350ms after a measured re-enable)
//  and the floor-violation breadcrumb (direct, postmortem-visible evidence of
//  the governor overriding the pinned floor).
//

import CoreMedia
import QuartzCore
import os

extension FramePacer {

    // MARK: - Tuning (colocated with the logic, like FrameRateRange's hysteresis)

    /// Realized-rate measurement window. 250ms is the spec'd sustain for the
    /// degraded mode ("realized tick rate sags below stream fps for >250ms"):
    /// one full deficient window IS the sustain proof. Short enough to engage
    /// within ~0.5s of collapse onset (today's stalls ran 1-6s); long enough
    /// that the steady-state main-runloop callback misses (~1-2/s, the
    /// microstutter class) cannot dent a window below the enter ratio - losing
    /// HALF a window's callbacks is a genuine collapse, not jitter.
    static let rateWindowSeconds = 0.25
    /// Enter the deficit below this fraction of expected ticks. 0.5 sits far
    /// under the wired divisor-decimation ratio (119.996Hz on a 170fps stream
    /// ≈ 0.71×) so the wired 4K240 regression baseline never engages, while
    /// today's collapses (10-58 ticks/s vs 120 expected = 0.08-0.48×) all do.
    static let deficitEnterTickRatio = 0.5
    /// Exit (and warm-handover-complete) at this fraction - the wide 0.5/0.8
    /// hysteresis band makes flapping structurally impossible.
    static let deficitExitTickRatio = 0.8
    /// Consecutive healthy windows (~0.5s, ≥ a few dozen real ticks at 120Hz)
    /// a rebuilt link must deliver before a warm handover cuts over to paced
    /// release. Two windows so the link's delayed/discontinuous first ticks
    /// (acknowledged in the re-enable grace comments) can't fake health.
    static let warmHandoverHealthyWindows = 2
    /// Floor-violation NOTICE: realized ticks below this fraction of the pinned
    /// floor - 10% under, so honest vsync-timing wobble around the floor never
    /// fires it - sustained for `floorViolationNoticeSeconds`.
    static let floorViolationRatio = 0.9
    static let floorViolationNoticeSeconds = 1.0
    /// Repaint the current frame during a deficit only after this many stream
    /// intervals without a REAL release (a real release is itself a commit, so
    /// repaints matter only when the host also faded / the queue ran dry).
    static let repaintAfterIdleIntervals = 2.0
    /// A rate window stretched past this many `rateWindowSeconds` is DISCARDED
    /// un-judged (re-seed, measure fresh). The window is rolled by main-runloop
    /// callers (tick, 20Hz watchdog, deficit timer) at ≥4Hz whenever the pacer
    /// is being judged at all, so an oversized window means the SERVICE callers
    /// themselves were paused (a suppressed span the watchdog bails on, a
    /// modal main-thread stall) - non-ticking-BY-DESIGN time that must never
    /// feed a realized-rate verdict. A genuine governor collapse cannot hide
    /// here: through every measured collapse the 20Hz watchdog (a Timer, not
    /// vsync-coupled) kept servicing, so its windows stay ~250ms and judged.
    static let rateWindowDiscardFactor = 4.0
    /// Hold deficit / floor-violation VERDICTS for this long after the
    /// suppression-clear edge (two full windows): the refocused window's link
    /// resumes ticking with delayed, discontinuous first callbacks - exactly
    /// the warm-handover concern, here in miniature - and judging that span
    /// minted all 8 false deficit engages + the 1 false FLOOR VIOLATION
    /// observed. Cost bound: a REAL governor collapse beginning at the
    /// refocus instant is detected ≤0.5s later than otherwise, well inside the
    /// watchdog's own 1.75s sustained-trip requirement; measurement (window
    /// rolls) continues throughout, only the verdicts wait.
    static let resumeVerdictHoldSeconds = 0.5
    /// Warm re-enable floor seed: the refined content cadence the
    /// last STOPPED pacer learned, stashed so a re-enabled pacer can seed from
    /// the truth (a wired-link warm re-enable installed floor=240.0Hz from
    /// the configured fps while content actually ran ~174.4Hz). Statics
    /// are safe process-wide for the same reason `lastTickTargetTimestamp` is:
    /// exactly one streaming session exists at a time, and the give-up's
    /// stop() re-stashes before any re-enable can adopt. Main-actor (stop()
    /// and start() both are); freshness-bounded so a stale session can't leak.
    @MainActor static var stashedRefinedIntervalSeconds: Double = .nan
    @MainActor static var stashedRefinedIntervalAt: CFTimeInterval = .nan
    /// Adopt the stash only this soon after it was written (the re-enable
    /// fires ~5s after the give-up; older is a different era's cadence), and
    /// only when the PTS-median had real history behind it (half the 64-delta
    /// window) - a pacer stopped pre-convergence would stash the configured
    /// seed, which is exactly what adoption exists to avoid.
    static let refinedCadenceStashMaxAgeSeconds = 30.0
    static let refinedCadenceStashMinSamples = 32

    /// One state transition the locked service pass detected, surfaced so the
    /// caller can log / reconcile the timer OFF the lock (LogStore takes its
    /// own lock; DispatchSource ops allocate - neither belongs under the
    /// pacer's hot os_unfair_lock).
    enum TickDeficitEvent {
        case deficitEngaged(ticksPerS: Double, expectedHz: Double, depth: Int)
        case deficitDisengaged(
            reason: String, durationSeconds: Double, releases: UInt64,
            repaints: UInt64, ticksPerS: Double)
        case floorViolation(ticksPerS: Double, floorHz: Double)
        case floorRecovered(durationSeconds: Double, ticksPerS: Double)
        case warmHandoverComplete(ticksPerS: Double)
    }

    // MARK: - The service pass (under `lock`)

    /// Roll the realized-rate window if one is due and advance the deficit /
    /// floor-violation / warm-handover state machines off the MEASURED rates.
    /// Called under `lock` from `handleTick`, `livenessSnapshot` (the 20Hz
    /// watchdog - the caller guaranteed alive when ticks stop entirely), and
    /// the deficit timer. Multiple callers are safe: the window rolls at most
    /// once per `rateWindowSeconds`, and only the roller observes transitions.
    func serviceTickDeficitLocked(now: CFTimeInterval) -> [TickDeficitEvent] {
        guard running else { return [] }
        guard tickDeficit.rateWindowStartHostTime.isFinite else {
            // First service after start - seed and measure from here.
            tickDeficit.rateWindowStartHostTime = now
            tickDeficit.rateWindowStartTicks = liveness.tickCount
            tickDeficit.rateWindowStartReleases = liveness.releaseCount
            return []
        }
        let elapsed = now - tickDeficit.rateWindowStartHostTime
        guard elapsed >= FramePacer.rateWindowSeconds else { return [] }
        // SERVICE-GAP DISCARD: an oversized window spans time nobody was
        // servicing (suppressed span / modal stall) - re-seed and measure only
        // fresh, serviced time instead of judging by-design-silent ticks. See
        // `rateWindowDiscardFactor` for why a real collapse can't hide here.
        if elapsed > FramePacer.rateWindowSeconds * FramePacer.rateWindowDiscardFactor {
            reseedRateWindowLocked(now: now)
            return []
        }
        let ticksPerS = Double(liveness.tickCount &- tickDeficit.rateWindowStartTicks) / elapsed
        let releasesPerS = Double(liveness.releaseCount &- tickDeficit.rateWindowStartReleases) / elapsed
        tickDeficit.measuredTicksPerSecond = ticksPerS
        tickDeficit.measuredReleasesPerSecond = releasesPerS
        tickDeficit.rateWindowStartHostTime = now
        tickDeficit.rateWindowStartTicks = liveness.tickCount
        tickDeficit.rateWindowStartReleases = liveness.releaseCount

        // Expected tick rate = min(stream Hz, NOMINAL panel Hz). The nominal
        // link duration keeps reading the panel's rated cadence even while
        // callbacks are throttled (refresh_changed=0 through every collapse),
        // so it is the honest "what should arrive" bar - and it keeps
        // fps>refresh setups (ticks legitimately below stream rate) from ever
        // reading as a deficit. Falls back to stream Hz before the first tick.
        let streamHz = streamFrameIntervalSeconds > 0
            ? 1.0 / streamFrameIntervalSeconds : 60.0
        let nominalHz = refreshTelemetry.lastRefreshIntervalSeconds.isFinite && refreshTelemetry.lastRefreshIntervalSeconds > 0
            ? 1.0 / refreshTelemetry.lastRefreshIntervalSeconds : streamHz
        let expectedHz = min(streamHz, nominalHz)
        tickDeficit.lastExpectedTickHz = expectedHz

        // Suppressed presentation: the link stops ticking BY DESIGN (window
        // hidden), the exact mirror of the watchdog's suppression bail. A
        // non-ticking hidden layer is not a fault - clear everything so the
        // machinery re-arms clean on refocus.
        if presentSuppressed {
            return clearForSuppressionLocked(now: now)
        }
        // RESUME-EDGE VERDICT HOLD (armed by the suppression-clear edge in
        // setPresentSuppressed): measurement continues - the window above
        // rolled and the rates updated - but no deficit / floor-violation
        // latch may form off the rebound link's delayed first ticks. Latches
        // are kept cleared so backdating can't reach into the held span.
        if tickDeficit.deficitVerdictHoldUntilHostTime.isFinite {
            guard now >= tickDeficit.deficitVerdictHoldUntilHostTime else {
                tickDeficit.tickDeficitSince = .nan
                tickDeficit.floorViolationSince = .nan
                tickDeficit.floorViolationLogged = false
                return []
            }
            tickDeficit.deficitVerdictHoldUntilHostTime = .nan
        }
        if tickDeficit.warmingUp {
            // A priming rebuilt link is ALREADY direct-presenting (the warm
            // handover path in submit). Engaging the deficit timer or judging
            // the floor against its delayed first ticks would be noise - only
            // the handover verdict runs until the link proves healthy.
            return serviceWarmHandoverLocked(ticksPerS: ticksPerS, expectedHz: expectedHz)
        }
        var events = trackDeficitLocked(
            now: now, windowSeconds: elapsed, ticksPerS: ticksPerS, expectedHz: expectedHz)
        events.append(contentsOf: trackFloorViolationLocked(
            now: now, windowSeconds: elapsed, ticksPerS: ticksPerS))
        return events
    }

    /// Deficit tracking + degraded-mode engage/disengage. Under `lock`.
    private func trackDeficitLocked(
        now: CFTimeInterval, windowSeconds: Double, ticksPerS: Double, expectedHz: Double
    ) -> [TickDeficitEvent] {
        // Hysteresis latch on the MEASURED rate. The deficit onset is backdated
        // to the window start: the whole deficient window is measured deficit,
        // so engage (below) and the watchdog's sustained trip both clock from
        // when the sag actually began, not when we noticed. `liveness.tickCount > 0`:
        // before the link's first-ever tick a low window is "link not started
        // yet" (the linkDead watchdog's territory), not a measured sag - keeps
        // a slow cold-start bind from minting a fake deficit breadcrumb.
        if liveness.tickCount > 0, ticksPerS < FramePacer.deficitEnterTickRatio * expectedHz {
            if !tickDeficit.tickDeficitSince.isFinite { tickDeficit.tickDeficitSince = now - windowSeconds }
        } else if ticksPerS >= FramePacer.deficitExitTickRatio * expectedHz {
            tickDeficit.tickDeficitSince = .nan
        }

        if tickDeficit.deficitModeActive {
            guard !tickDeficit.tickDeficitSince.isFinite else { return [] }
            // Ticks are back (≥0.8× expected for a full window) - hand release
            // back to the real vsync. FULLY self-recovering: nothing latches.
            tickDeficit.deficitModeActive = false
            let duration = tickDeficit.deficitEngagedAt.isFinite ? now - tickDeficit.deficitEngagedAt : 0
            let released = liveness.releaseCount &- tickDeficit.deficitEngageReleaseCount
            let repaints = tickDeficit.deficitRepaints
            tickDeficit.deficitEngagedAt = .nan
            tickDeficit.lastRepaintHostTime = .nan
            return [.deficitDisengaged(
                reason: "ticks recovered", durationSeconds: duration,
                releases: released, repaints: repaints, ticksPerS: ticksPerS)]
        }
        // Engage only with frames QUEUED: an empty queue during a tick sag is a
        // wire/decode drought (the RFI/decode machinery's to recover) or a
        // static scene - in neither case is there anything to release. The
        // depth>0 + measured-deficit pair is the same fault signature the
        // watchdog trips on, caught here within ~one window instead of seconds.
        guard tickDeficit.tickDeficitSince.isFinite, !queue.isEmpty else { return [] }
        tickDeficit.deficitModeActive = true
        tickDeficit.deficitEngagedAt = now
        tickDeficit.deficitEngageReleaseCount = liveness.releaseCount
        tickDeficit.deficitRepaints = 0
        tickDeficit.lastRepaintHostTime = .nan
        return [.deficitEngaged(
            ticksPerS: ticksPerS, expectedHz: expectedHz, depth: queue.count)]
    }

    /// Floor-violation breadcrumb tracking (item: direct governor evidence -
    /// realized ticks below the PINNED preferredFrameRateRange floor for >1s
    /// proves the floor is being overridden, answering the re-pin co-trigger
    /// question one battery repro session could not). Under `lock`.
    private func trackFloorViolationLocked(
        now: CFTimeInterval, windowSeconds: Double, ticksPerS: Double
    ) -> [TickDeficitEvent] {
        let floor = tickDeficit.pinnedFloorHz
        guard floor.isFinite, floor > 0 else { return [] }
        if ticksPerS < floor * FramePacer.floorViolationRatio {
            if !tickDeficit.floorViolationSince.isFinite { tickDeficit.floorViolationSince = now - windowSeconds }
            if !tickDeficit.floorViolationLogged,
               now - tickDeficit.floorViolationSince >= FramePacer.floorViolationNoticeSeconds {
                // Once per episode - a multi-second collapse logs one NOTICE,
                // not one per window.
                tickDeficit.floorViolationLogged = true
                return [.floorViolation(ticksPerS: ticksPerS, floorHz: floor)]
            }
            return []
        }
        let wasLogged = tickDeficit.floorViolationLogged
        let since = tickDeficit.floorViolationSince
        tickDeficit.floorViolationSince = .nan
        tickDeficit.floorViolationLogged = false
        guard wasLogged, since.isFinite else { return [] }
        return [.floorRecovered(durationSeconds: now - since, ticksPerS: ticksPerS)]
    }

    /// Warm-handover verdict: cut over to paced release only after the rebuilt
    /// link delivers consecutive healthy windows. Under `lock`.
    private func serviceWarmHandoverLocked(
        ticksPerS: Double, expectedHz: Double
    ) -> [TickDeficitEvent] {
        if ticksPerS >= FramePacer.deficitExitTickRatio * expectedHz {
            tickDeficit.warmHealthyWindowStreak += 1
            guard tickDeficit.warmHealthyWindowStreak >= FramePacer.warmHandoverHealthyWindows else {
                return []
            }
            // ATOMIC flip under the lock: the very next submit queues instead
            // of direct-presenting. The queue is empty here (everything so far
            // went direct), so resetting the cadence base reproduces the clean
            // session-start state - first tick releases immediately and
            // re-seeds the grid from the live link's clock.
            tickDeficit.warmingUp = false
            tickDeficit.warmHealthyWindowStreak = 0
            resetCadenceBaseLocked()
            return [.warmHandoverComplete(ticksPerS: ticksPerS)]
        }
        tickDeficit.warmHealthyWindowStreak = 0
        return []
    }

    /// Suppression-edge clear. Under `lock`. The link stopping while hidden is
    /// by design, so no deficit/violation state may survive into (or be minted
    /// during) a suppressed span. Module-internal (not private): the
    /// suppression EDGES in setPresentSuppressed (FramePacer+Submit.swift)
    /// call it too, so a deficit episode live at the hide instant disengages
    /// immediately instead of leaving the off-tick timer spinning while hidden.
    func clearForSuppressionLocked(now: CFTimeInterval) -> [TickDeficitEvent] {
        tickDeficit.tickDeficitSince = .nan
        tickDeficit.floorViolationSince = .nan
        tickDeficit.floorViolationLogged = false
        tickDeficit.warmHealthyWindowStreak = 0
        guard tickDeficit.deficitModeActive else { return [] }
        tickDeficit.deficitModeActive = false
        let duration = tickDeficit.deficitEngagedAt.isFinite ? now - tickDeficit.deficitEngagedAt : 0
        let released = liveness.releaseCount &- tickDeficit.deficitEngageReleaseCount
        let repaints = tickDeficit.deficitRepaints
        tickDeficit.deficitEngagedAt = .nan
        tickDeficit.lastRepaintHostTime = .nan
        return [.deficitDisengaged(
            reason: "presentation suppressed", durationSeconds: duration,
            releases: released, repaints: repaints, ticksPerS: 0)]
    }

    /// Re-seed the realized-rate window from `now` and void the published
    /// rates ("no fresh measurement yet" - the watchdog's tick-deficit trip
    /// requires finite rates, so nothing can trip off stale numbers). Used by
    /// the suppression-clear edge (the deficit machinery must measure only
    /// un-suppressed time) and the oversized-window discard. Under `lock`.
    func reseedRateWindowLocked(now: CFTimeInterval) {
        tickDeficit.rateWindowStartHostTime = now
        tickDeficit.rateWindowStartTicks = liveness.tickCount
        tickDeficit.rateWindowStartReleases = liveness.releaseCount
        tickDeficit.measuredTicksPerSecond = .nan
        tickDeficit.measuredReleasesPerSecond = .nan
    }

    /// Reset EVERY tick-deficit / warm-handover / floor-violation field and
    /// release the held repaint frame - the stop() reset, colocated with the
    /// state machine it clears so a new field can't be forgotten in a far-away
    /// teardown list (`tickDeficit.deficitVerdictHoldUntilHostTime` nearly was). Under `lock`.
    func resetTickDeficitStateLocked() {
        tickDeficit.rateWindowStartHostTime = .nan
        tickDeficit.rateWindowStartTicks = 0
        tickDeficit.rateWindowStartReleases = 0
        tickDeficit.measuredTicksPerSecond = .nan
        tickDeficit.measuredReleasesPerSecond = .nan
        tickDeficit.lastExpectedTickHz = .nan
        tickDeficit.tickDeficitSince = .nan
        tickDeficit.deficitVerdictHoldUntilHostTime = .nan
        tickDeficit.deficitModeActive = false
        tickDeficit.deficitEngagedAt = .nan
        tickDeficit.deficitRepaints = 0
        tickDeficit.lastRepaintHostTime = .nan
        tickDeficit.lastPresentedSampleBuffer = nil
        tickDeficit.warmingUp = false
        tickDeficit.warmHealthyWindowStreak = 0
        tickDeficit.floorViolationSince = .nan
        tickDeficit.floorViolationLogged = false
        tickDeficit.pinnedFloorHz = .nan
    }

    // MARK: - Warm re-enable cadence stash

    /// Stash this pacer's refined content cadence at stop() so the NEXT pacer
    /// - if it is a warm re-enable - seeds its floor from the truth. Only
    /// stashes a genuinely refined estimate (see the constants); takes the
    /// lock itself, so call it OFF the lock. MainActor: the statics are.
    @MainActor
    func stashRefinedCadenceForWarmReenable() {
        os_unfair_lock_lock(&lock)
        let interval = streamFrameIntervalSeconds
        let refined = ptsDeltas.count >= FramePacer.refinedCadenceStashMinSamples
        os_unfair_lock_unlock(&lock)
        guard refined, interval.isFinite, interval > 0 else { return }
        FramePacer.stashedRefinedIntervalSeconds = interval
        FramePacer.stashedRefinedIntervalAt = CFAbsoluteTimeGetCurrent()
    }

    /// Adopt the stashed refined cadence into a WARM-HANDOVER pacer before its
    /// link installs (called from start() under `lock`; armWarmHandover ran
    /// first on the re-enable path, so `tickDeficit.warmingUp` distinguishes it). This
    /// fix: without this, installLink pinned floor = configured fps (240.0Hz)
    /// while content ran ~174.4 - a dishonest floor for the rebuilt link's
    /// first beats and a wrong `expectedHz` bar for the handover verdict. A
    /// cold session start (tickDeficit.warmingUp false) keeps the configured seed - its
    /// predecessor (if any) is a torn-down SESSION, not the same stream.
    @MainActor
    func adoptStashedRefinedCadenceLocked() {
        guard tickDeficit.warmingUp else { return }
        let stashed = FramePacer.stashedRefinedIntervalSeconds
        let stashedAt = FramePacer.stashedRefinedIntervalAt
        guard stashed.isFinite, stashedAt.isFinite,
              CFAbsoluteTimeGetCurrent() - stashedAt
                < FramePacer.refinedCadenceStashMaxAgeSeconds else { return }
        streamFrameIntervalSeconds = FramePacer.clampFrameInterval(stashed)
    }

    // MARK: - Event handling (OFF the lock)

    /// Log the transitions and reconcile the off-tick timer. Callable from any
    /// thread; Diag/LogStore lines land in the glimmer-*.log file sink so every
    /// engage/disengage is postmortem-visible (the os_log-only breadcrumb class
    /// this pass retires).
    func handleTickDeficitEvents(_ events: [TickDeficitEvent]) {
        guard !events.isEmpty else { return }
        var reconcile = false
        for event in events {
            switch event {
            case let .deficitEngaged(ticksPerS, expectedHz, depth):
                reconcile = true
                log.warning(
                    // swiftlint:disable:next line_length
                    "FramePacer tick-deficit degraded mode ENGAGED - measured ticks \(ticksPerS, privacy: .public)/s vs expected \(expectedHz, privacy: .public)Hz, depth=\(depth, privacy: .public); releasing off-tick at stream cadence")
                Diag.notice(
                    "FramePacer tick-deficit degraded mode ENGAGED - measured ticks "
                    + "\(String(format: "%.1f", ticksPerS))/s vs expected "
                    + "\(String(format: "%.1f", expectedHz))Hz, depth=\(depth); "
                    + "releasing off-tick at stream cadence until ticks recover",
                    "Stream.Pacer")
                OSSignposter.render.emitEvent(
                    "PacerTickDeficitEngaged",
                    "ticksPerS=\(ticksPerS, privacy: .public) depth=\(depth, privacy: .public)")
            case let .deficitDisengaged(reason, duration, releases, repaints, ticksPerS):
                reconcile = true
                log.notice(
                    // swiftlint:disable:next line_length
                    "FramePacer tick-deficit degraded mode DISENGAGED (\(reason, privacy: .public)) after \(duration * 1000, privacy: .public)ms - released \(releases, privacy: .public) frames off-tick, \(repaints, privacy: .public) governor repaints, ticks now \(ticksPerS, privacy: .public)/s")
                Diag.info(
                    "FramePacer tick-deficit degraded mode DISENGAGED (\(reason)) after "
                    + "\(String(format: "%.0f", duration * 1000))ms - released \(releases) "
                    + "frames off-tick, \(repaints) governor repaints",
                    "Stream.Pacer")
                OSSignposter.render.emitEvent(
                    "PacerTickDeficitDisengaged",
                    "durationMs=\(duration * 1000, privacy: .public) releases=\(releases, privacy: .public)")
            case let .floorViolation(ticksPerS, floorHz):
                log.notice(
                    // swiftlint:disable:next line_length
                    "FramePacer FLOOR VIOLATION - realized ticks \(ticksPerS, privacy: .public)/s below the pinned \(floorHz, privacy: .public)Hz preferredFrameRateRange floor for >1s (frame-rate governor overriding the advisory floor)")
                Diag.notice(
                    "FramePacer FLOOR VIOLATION - realized ticks "
                    + "\(String(format: "%.1f", ticksPerS))/s below the pinned "
                    + "\(String(format: "%.1f", floorHz))Hz floor for >1s "
                    + "(frame-rate governor overriding the advisory floor)",
                    "Stream.Pacer")
                OSSignposter.render.emitEvent(
                    "PacerFloorViolation",
                    "ticksPerS=\(ticksPerS, privacy: .public) floorHz=\(floorHz, privacy: .public)")
            case let .floorRecovered(duration, ticksPerS):
                Diag.info(
                    "FramePacer floor violation cleared after "
                    + "\(String(format: "%.0f", duration * 1000))ms - ticks back at "
                    + "\(String(format: "%.1f", ticksPerS))/s",
                    "Stream.Pacer")
            case let .warmHandoverComplete(ticksPerS):
                log.notice(
                    // swiftlint:disable:next line_length
                    "FramePacer warm handover complete - rebuilt link healthy at \(ticksPerS, privacy: .public) ticks/s; paced release engaged")
                Diag.info(
                    "FramePacer warm handover complete - rebuilt link healthy at "
                    + "\(String(format: "%.1f", ticksPerS)) ticks/s; paced release engaged",
                    "Stream.Pacer")
                OSSignposter.render.emitEvent(
                    "PacerWarmHandoverComplete", "ticksPerS=\(ticksPerS, privacy: .public)")
            }
        }
        if reconcile {
            pacingQueue.async { [weak self] in self?.reconcileDeficitTimer() }
        }
    }

    // MARK: - The off-tick release timer (pacingQueue-confined)

    /// Create/cancel the off-tick timer to match the lock-guarded desired state.
    /// Runs ONLY on `pacingQueue`, so `deficitTimer` itself needs no lock - the
    /// idempotent reconcile shape means racing engage/disengage transitions
    /// converge on the latest state instead of double-arming.
    func reconcileDeficitTimer() {
        os_unfair_lock_lock(&lock)
        let want = tickDeficit.deficitModeActive && running
        let interval = streamFrameIntervalSeconds
        os_unfair_lock_unlock(&lock)
        if want, tickDeficit.deficitTimer == nil {
            let timer = DispatchSource.makeTimerSource(queue: pacingQueue)
            timer.schedule(
                deadline: .now() + interval, repeating: interval,
                leeway: .milliseconds(1))
            timer.setEventHandler { [weak self] in self?.deficitTimerFired() }
            tickDeficit.deficitTimer = timer
            timer.resume()
        } else if !want, let timer = tickDeficit.deficitTimer {
            timer.cancel()
            tickDeficit.deficitTimer = nil
        }
    }

    /// One off-tick beat: run the NORMAL release pipeline (trim → backoff →
    /// due-gate, every safeguard intact) against a synthetic vsync, then
    /// repaint for the governor if nothing real flowed. `CACurrentMediaTime()`
    /// shares CADisplayLink's timebase, so the cadence base stays on one clock
    /// - when real ticks resume mid-deficit their targetTimestamps slot onto
    /// the same grid and the due gate just keeps pacing (releases stay capped
    /// at one per stream interval no matter how the two sources interleave).
    func deficitTimerFired() {
        os_unfair_lock_lock(&lock)
        let active = tickDeficit.deficitModeActive && running && !presentSuppressed
        let interval = streamFrameIntervalSeconds
        os_unfair_lock_unlock(&lock)
        guard active else { return }
        releaseDueFrame(
            targetTimestamp: CACurrentMediaTime(), vsyncInterval: interval)
        maybeRepaintForGovernor(interval: interval)
        // Keep the rate window rolling from here too: with ticks FULLY stopped
        // and the watchdog mid-teardown there may be no other caller, and the
        // disengage verdict must never depend on the thing that failed.
        let now = CFAbsoluteTimeGetCurrent()
        os_unfair_lock_lock(&lock)
        let events = serviceTickDeficitLocked(now: now)
        os_unfair_lock_unlock(&lock)
        handleTickDeficitEvents(events)
    }

    /// Re-commit the most recently presented frame so the governor sees a live
    /// layer even when the host also faded (the measured ordering evidence:
    /// commits stopping is the suspected downclock trigger - one collapse
    /// PRECEDED its host dip by ~1.5s). Only after ≥2 stream
    /// intervals without a REAL release (a real release is itself a commit),
    /// rate-limited to stream cadence, and never counted as a rendered frame -
    /// the renders==received verification contract stays honest.
    func maybeRepaintForGovernor(interval: Double) {
        let now = CFAbsoluteTimeGetCurrent()
        var repaint: CMSampleBuffer?
        os_unfair_lock_lock(&lock)
        let sinceRelease = liveness.lastReleaseHostTime.isFinite
            ? now - liveness.lastReleaseHostTime : .infinity
        let sinceRepaint = tickDeficit.lastRepaintHostTime.isFinite
            ? now - tickDeficit.lastRepaintHostTime : .infinity
        if tickDeficit.deficitModeActive, !presentSuppressed,
           sinceRelease > interval * FramePacer.repaintAfterIdleIntervals,
           sinceRepaint >= interval,
           let sampleBuffer = tickDeficit.lastPresentedSampleBuffer {
            tickDeficit.lastRepaintHostTime = now
            tickDeficit.deficitRepaints &+= 1
            repaint = sampleBuffer
        }
        os_unfair_lock_unlock(&lock)
        guard let repaint else { return }
        onDeficitRepaint?(repaint)
    }

    // MARK: - Warm handover entry points

    /// Arm the warm handover BEFORE `start(drivingView:)` on a re-enabled pacer:
    /// submits direct-present (bypassing the queue) until the rebuilt link
    /// delivers `warmHandoverHealthyWindows` consecutive windows at ≥0.8× the
    /// expected tick rate. The cold cutover this replaces handed arriving
    /// 110fps straight to an un-primed link's queue - depth snapped to the cap
    /// and the stream re-froze 350ms after re-enable (the re-enable hiccup was
    /// itself a felt freeze, separate from the original stall).
    func armWarmHandover() {
        os_unfair_lock_lock(&lock)
        tickDeficit.warmingUp = true
        tickDeficit.warmHealthyWindowStreak = 0
        os_unfair_lock_unlock(&lock)
    }

    /// Direct-present one frame during warm-up (called from `submit` on the VT
    /// decode queue - the same thread the pre-pacer fallback path proves safe).
    /// Stamps the release liveness clocks: a frame DID reach the renderer, and
    /// the watchdog must see the flow as healthy while the link primes. A
    /// renderer refusal counts toward the reject streak - a latched-unready
    /// renderer during warm-up is the same renderer-refusal wedge class and
    /// must steer the ladder to the flush, not to link medicine.
    func presentWarmHandoverFrame(_ entry: Entry) {
        guard let willPresent else { return }
        guard willPresent(entry.sampleBuffer) else {
            noteGateReleaseRejected()
            return
        }
        noteFramePresented(entry.sampleBuffer)
    }
}
