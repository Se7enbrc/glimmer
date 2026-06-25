//
//  FramePacer+Recovery.swift
//
//  The present-path self-heal watchdog actions + present-side liveness /
//  refresh-window telemetry snapshots + the single link-bind path
//  (`installLink`). Split out of FramePacer.swift to keep that file under the
//  length limit; these are the recovery escalations the external watchdog
//  (StreamSession) drives - rebind/rebuild the link, force a release,
//  direct-drain, drop-to-newest, clear - plus the consistent state reads it
//  gates on. The nested snapshot types (`LivenessSnapshot`,
//  `RefreshWindowSnapshot`) are declared here with the methods that build them.
//

import AppKit
import AVFoundation
import CoreMedia
import QuartzCore
import os

extension FramePacer {

    // MARK: - Snapshot types

    /// A snapshot of the pacer's present-side health, read by the external
    /// watchdog (StreamSession) and the NOTICE instrumentation. All fields are
    /// read under the lock in one shot so they're mutually consistent.
    struct LivenessSnapshot {
        /// Seconds since the last `handleTick` (link liveness). `.infinity`
        /// before the first tick. A 240Hz link ticks every ~4.17ms; a large
        /// value means the CADisplayLink has stopped.
        let secondsSinceLastTick: Double
        /// Seconds since the last frame actually reached the renderer.
        /// `.infinity` before the first release.
        let secondsSinceLastRelease: Double
        /// Frames currently waiting in the jitter buffer. A non-empty queue
        /// combined with a stale `secondsSinceLastRelease` is the wedge.
        let depth: Int
        /// Whether the pacer is between start() and stop().
        let running: Bool
        /// Cumulative tick count since start() - the instrumentation derives a
        /// ticks/sec rate by differencing against the previous window's value.
        let totalTicks: UInt64
        /// Cumulative release count since start() - same, for presents/sec.
        let totalReleases: UInt64
        /// Learned stream frame interval (seconds) - surfaced so the
        /// instrumentation can show what cadence the gate is pacing against.
        let streamFrameIntervalSeconds: Double
        /// Current jitter-driven adaptive target depth (1 on a clean link -
        /// passthrough rest state - up to `maxTargetDepth` under sustained
        /// MEASURED jitter) - surfaced so the metric line shows how deep the
        /// adaptive buffer is currently riding.
        let adaptiveTargetDepth: Int
        /// MEASURED realized tick/release rates from the pacer's own rolling
        /// ~250ms window (FramePacer+TickDeficit.swift), `.nan` until the first
        /// window completes. The watchdog's tick-deficit trip keys on these -
        /// measured, never inferred - so a partial-rate tick collapse (13-58
        /// ticks/s against a 120fps stream) is finally visible to it.
        let recentTicksPerSecond: Double
        let recentReleasesPerSecond: Double
        /// How long (seconds) the measured tick rate has been in deficit
        /// against `expectedTickHz` (hysteresis: enter <0.5×, clear ≥0.8×).
        /// 0 when healthy. The watchdog trips on this SUSTAINED, with the
        /// release rate also collapsed - i.e. only when the in-pacer degraded
        /// mode did NOT keep frames flowing.
        let tickDeficitSeconds: Double
        /// What the tick rate SHOULD be: min(stream Hz, nominal panel Hz).
        /// `.nan` until the first window completes.
        let expectedTickHz: Double
        /// True while the off-tick degraded release path is active.
        let tickDeficitModeActive: Bool
        /// Consecutive pacer-path releases the RENDERER refused (willPresent
        /// false), 0 after any successful present. A high streak alongside a
        /// stale release clock means the gate is releasing fine and the
        /// renderer is the wedged organ (the renderer-refusal class) - the
        /// ladder reaches for the flush instead of cadence/link medicine.
        let presentRejectStreak: Int
    }

    /// Per-second display-refresh telemetry: the realized vsync cadence over the
    /// window SINCE THE LAST CALL (min/avg/max derived refresh Hz) plus whether a
    /// refresh CHANGE was seen in that window. RESET-ON-READ - so it must be
    /// called by exactly ONE consumer at the publish cadence (the 1Hz exporter),
    /// NOT the 20Hz watchdog or 2Hz metric timer (which use the non-destructive
    /// `livenessSnapshot`). All nil when no tick landed this window (link idle /
    /// torn down). Hz is derived as 1/interval; min-interval ⇒ max-Hz and vice
    /// versa, so we map accordingly (a long interval = a LOW refresh, the
    /// ProMotion ramp-down).
    struct RefreshWindowSnapshot {
        let minHz: Double?
        let avgHz: Double?
        let maxHz: Double?
        let changed: Bool
    }

    // MARK: - Link bind (the single path start / screen-change / rebuild use)

    @MainActor
    func installLink(on view: NSView) {
        // `NSView.displayLink(target:selector:)` (macOS 14+) creates a link
        // tied to the display the view is currently on and tracks it as the
        // view moves between screens - exactly the binding moonlight-qt builds
        // by hand with CVDisplayLinkCreateWithCGDisplay against the window's
        // NSScreen. We add it (in the common modes) to the private tick run loop
        // by default - the off-main path that un-starves the callback - or to
        // `.main` when the flag is off; either keeps it firing across UI beats.
        // Reset the cadence base BEFORE the new link starts ticking, so the
        // first tick on the new (possibly discontinuous) timebase re-seeds
        // `lastPresentMediaTime` from this link's clock instead of comparing
        // against a stale value from the old link - the negative-`sinceLast`
        // wedge that hard-froze the stream. See `resetCadenceBaseLocked`.
        os_unfair_lock_lock(&lock)
        resetCadenceBaseLocked()
        os_unfair_lock_unlock(&lock)

        let proxy = DisplayLinkProxy { [weak self] link in
            self?.handleTick(link)
        }
        let link = view.displayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick(_:)))
        // FORBID macOS from throttling the PRESENT CALLBACK below stream
        // cadence on a static/AFK layer. Without a floor, macOS slows the
        // CADisplayLink callback on a flat layer (NOT a ProMotion display
        // ramp-down - the panel stayed 120Hz; it is the CALLBACK being
        // throttled), so received frames pile in the pacer FIFO to the cap and
        // late-drop (on a lossy wifi link: drops_presentation_late = 38% of all
        // frames, fps_rendered→0 while decode tracked received). Pinning the link
        // to the STREAM cadence keeps the present callback firing at least once
        // per stream frame even on a static scene, so queued frames keep
        // presenting and the pile-up can't form. The floor is ADVISORY - the
        // battery/ProMotion governor demonstrably overrides it (measured on a
        // battery + ProMotion panel) - which is why the tick-deficit
        // degraded mode exists as the failsafe.
        //
        // We still read the realized cadence per tick from targetTimestamp, so a
        // variable-refresh panel is handled correctly inside [minimum, maximum].
        // CLAMP the floor to min(streamHz, panelMaxHz): on a sub-stream-fps panel
        // (e.g. 60Hz external + 120fps stream) the panel physically cannot tick
        // at streamHz, so requesting that floor is impossible and would be
        // ignored / mis-honored - the floor must never exceed the panel max.
        let panelMax = Self.panelMaxHz(for: view)
        let range = Self.preferredRange(
            forStreamIntervalSeconds: self.configuredFrameIntervalSeconds,
            panelMaxHz: panelMax)
        link.preferredFrameRateRange = range
        // Record the floor we just pinned so the per-tick re-apply only
        // re-pins on a real cadence drift past the hysteresis, not on every tick.
        // Re-seeded on every (re)bind / screen change because installLink is the
        // single bind path, so a rebuild onto a different panel re-clamps cleanly.
        self.appliedFloorHz = Double(range.minimum)
        // Mirror the floor under the lock for the off-main floor-violation
        // detector (the rate-window roll can't touch main-actor state).
        os_unfair_lock_lock(&lock)
        tickDeficit.pinnedFloorHz = Double(range.minimum)
        os_unfair_lock_unlock(&lock)
        // Add the link to the PRIVATE tick run loop (default) so the present
        // callback isn't starved when the main thread is busy - the governor
        // callback-gap that trimmed ~73% of clean-link frame drops. `.main` is
        // the instant fallback (flag off). The thread is created lazily and
        // reused across rebuilds (installLink is the single rebind path), so a
        // reconnect / screen change re-adds to it without spawning a second one.
        // The watchdog's tick-deficit/linkDead net (livenessSnapshot, a Timer)
        // still fires off-main, so even a non-firing off-main link self-heals.
        if Self.tickOffMain {
            let tickThread = pacerTickThread ?? PacerTickThread()
            pacerTickThread = tickThread
            tickThread.start()
            tickThread.add(link)
        } else {
            link.add(to: .main, forMode: .common)
        }
        self.setTickProxy(proxy)
        self.displayLink = link
        // Seed the bound-screen signature so `screenDidChange` can distinguish
        // a REAL move/mode change from ProMotion VRR-housekeeping notifications.
        self.boundScreenSignature = Self.screenSignature(for: view)
        // Diag/LogStore breadcrumb (postmortem-visible, unlike the os_log-only
        // lines, which never reach the glimmer-*.log file sink): every link
        // (re)bind - session start, screen change, watchdog rebuild - lands in
        // the session log with the exact range applied, so a collapse onset can
        // finally be correlated with a (re)bind/re-pin.
        Diag.info(
            // `preferred` is optional in the Swift interface; we always set it,
            // so the 0 fallback can't appear in practice.
            "FramePacer link installed - floor=\(Double(range.minimum))Hz "
            + "preferred=\(Double(range.preferred ?? 0))Hz max=\(Double(range.maximum))Hz "
            + "(panelMax=\(panelMax)Hz)",
            "Stream.Pacer")
    }

    /// Rebind the link to a new screen - the stream window moved to another
    /// display, or came back from display sleep. A CADisplayLink from
    /// `NSView.displayLink` follows the view's window automatically in most
    /// cases, but a hard screen change (and the sleep/wake transition where the
    /// old link silently stops) is safest handled by rebuilding. No-op when not
    /// running.
    @MainActor
    func screenDidChange() {
        let isRunning: Bool = {
            os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
            return running
        }()
        guard isRunning, let view = boundView else { return }
        // MATERIAL-CHANGE GATE: macOS posts screen-parameter notifications
        // ~1/s on a ProMotion panel (VRR housekeeping) with nothing actually
        // changed - 785 unconditional rebinds in a ~12-minute wifi run,
        // each one resetting the cadence base the due-gate paces against (a
        // standing micro-judder source, invisible until the (re)bind
        // breadcrumbs landed). Rebind only when the screen identity, panel
        // max, or backing scale genuinely moved; the watchdog rebuild path
        // (`rebuildDisplayLink`) stays unconditional for silent same-screen
        // mode switches that change none of the three.
        let signature = Self.screenSignature(for: view)
        guard signature != boundScreenSignature else { return }
        log.info("FramePacer rebinding display link after screen change")
        Diag.info("FramePacer rebinding display link after screen change", "Stream.Pacer")
        displayLink?.invalidate()
        displayLink = nil
        installLink(on: view)
    }

    /// Compact identity of the screen `view` is on: display ID | panel max |
    /// backing scale. The three things whose change makes a rebind MATERIAL -
    /// anything else arriving via screen-parameter notifications is VRR/HDR
    /// housekeeping the bound link already follows. Falls back to "none" when
    /// the view has no window/screen yet, which never equals a real signature,
    /// so the degenerate case still rebinds (matching the old behavior).
    @MainActor
    static func screenSignature(for view: NSView) -> String {
        guard let screen = view.window?.screen else { return "none" }
        let displayID = (screen.deviceDescription[
            NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value ?? 0
        return "\(displayID)|\(screen.maximumFramesPerSecond)|\(screen.backingScaleFactor)"
    }

    /// Force-rebuild the CADisplayLink - the present-path watchdog's recovery
    /// action when the link has stopped ticking (a same-screen 240Hz HDR/VRR
    /// mode switch that posted no `didChangeScreen`, so `screenDidChange` never
    /// fired). Same path as `screenDidChange` but logs a self-heal cause so the
    /// recovery is visible in the field. No-op if not running. `installLink`
    /// resets the cadence base, so the first tick after the rebuild releases.
    @MainActor
    func rebuildLink(reason: String) {
        let isRunning: Bool = {
            os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
            return running
        }()
        guard isRunning, let view = boundView else { return }
        log.warning("FramePacer self-heal: rebuilding display link (\(reason, privacy: .public))")
        Diag.notice("FramePacer self-heal: rebuilding display link (\(reason))", "Stream.Pacer")
        OSSignposter.render.emitEvent("PacerLinkRebuild", "reason=\(reason, privacy: .public)")
        displayLink?.invalidate()
        displayLink = nil
        installLink(on: view)
    }

    // MARK: - Present-side liveness API (watchdog + instrumentation)

    /// Read + RESET the display-refresh window. See `RefreshWindowSnapshot`.
    func refreshWindowSnapshot() -> RefreshWindowSnapshot {
        os_unfair_lock_lock(&lock); defer { os_unfair_lock_unlock(&lock) }
        defer {
            refreshTelemetry.refreshIntervalSumSeconds = 0
            refreshTelemetry.refreshIntervalSamples = 0
            refreshTelemetry.refreshIntervalMinSeconds = .nan
            refreshTelemetry.refreshIntervalMaxSeconds = .nan
            refreshTelemetry.refreshChangedSinceRead = false
        }
        guard refreshTelemetry.refreshIntervalSamples > 0 else {
            return RefreshWindowSnapshot(minHz: nil, avgHz: nil, maxHz: nil,
                                         changed: refreshTelemetry.refreshChangedSinceRead)
        }
        let avgInterval = refreshTelemetry.refreshIntervalSumSeconds / Double(refreshTelemetry.refreshIntervalSamples)
        // A LONGER interval = a LOWER Hz: max interval → min Hz, min interval → max Hz.
        let minHz = refreshTelemetry.refreshIntervalMaxSeconds > 0 ? 1.0 / refreshTelemetry.refreshIntervalMaxSeconds : nil
        let maxHz = refreshTelemetry.refreshIntervalMinSeconds > 0 ? 1.0 / refreshTelemetry.refreshIntervalMinSeconds : nil
        let avgHz = avgInterval > 0 ? 1.0 / avgInterval : nil
        return RefreshWindowSnapshot(minHz: minHz, avgHz: avgHz, maxHz: maxHz,
                                     changed: refreshTelemetry.refreshChangedSinceRead)
    }

    /// One-shot consistent read of the present-side liveness state. ALSO rolls
    /// the realized-rate window when one is due: the 20Hz watchdog calls this
    /// continuously, so the tick-deficit measurement keeps advancing even when
    /// the CADisplayLink has stopped ticking entirely - the one caller that is
    /// guaranteed alive during the exact failure this machinery measures.
    func livenessSnapshot() -> LivenessSnapshot {
        let now = CFAbsoluteTimeGetCurrent()
        os_unfair_lock_lock(&lock)
        let events = serviceTickDeficitLocked(now: now)
        let sinceTick = liveness.lastTickHostTime.isFinite ? now - liveness.lastTickHostTime : .infinity
        let sinceRelease = liveness.lastReleaseHostTime.isFinite ? now - liveness.lastReleaseHostTime : .infinity
        let snapshot = LivenessSnapshot(
            secondsSinceLastTick: sinceTick,
            secondsSinceLastRelease: sinceRelease,
            depth: queue.count,
            running: running,
            totalTicks: liveness.tickCount,
            totalReleases: liveness.releaseCount,
            streamFrameIntervalSeconds: streamFrameIntervalSeconds,
            adaptiveTargetDepth: adaptiveDepth.adaptiveTargetDepth,
            recentTicksPerSecond: tickDeficit.measuredTicksPerSecond,
            recentReleasesPerSecond: tickDeficit.measuredReleasesPerSecond,
            tickDeficitSeconds: tickDeficit.tickDeficitSince.isFinite ? now - tickDeficit.tickDeficitSince : 0,
            expectedTickHz: tickDeficit.lastExpectedTickHz,
            tickDeficitModeActive: tickDeficit.deficitModeActive,
            presentRejectStreak: liveness.presentRejectStreak)
        os_unfair_lock_unlock(&lock)
        // Emit breadcrumbs / reconcile the off-tick timer OFF the lock (LogStore
        // takes its own lock; timer ops dispatch) - same discipline as handleTick.
        handleTickDeficitEvents(events)
        return snapshot
    }

    /// Escalation step the watchdog can take BEFORE rebuilding the link: re-anchor
    /// the cadence base ON the live grid so the next tick releases the head. Cheap
    /// and non-destructive - if ticks are still arriving (the gate is merely
    /// latched), this drains the wedge next vsync without a link rebuild. On-grid
    /// (not `.nan`, which re-latches a backoff-reseed wedge → this poke a no-op);
    /// the helper falls back to `.nan` if the link is gone. Returns the poke depth.
    @MainActor
    @discardableResult
    func forceReleaseNextTick(reason: String) -> Int {
        let target = displayLink?.targetTimestamp ?? .nan
        os_unfair_lock_lock(&lock)
        let depth = queue.count
        anchorCadenceBaseOnGridLocked(targetTimestamp: target)
        liveness.starvedTickStreak = 0
        os_unfair_lock_unlock(&lock)
        log.warning("FramePacer self-heal: force-release-next-tick (\(reason, privacy: .public)) depth=\(depth, privacy: .public)")
        Diag.notice(
            "FramePacer self-heal: force-release-next-tick (\(reason)) depth=\(depth)",
            "Stream.Pacer")
        OSSignposter.render.emitEvent("PacerForceReleaseNextTick", "depth=\(depth, privacy: .public)")
        return depth
    }

    /// Last-resort drain when the LINK itself is dead (no ticks arriving), so
    /// `forceReleaseNextTick` can't help - there will be no "next tick". Pushes
    /// the freshest queued frame straight through `willPresent`, bypassing the
    /// due gate, off the pacing queue. Keeps the screen alive while the link is
    /// rebuilt. Returns true if a frame was pushed.
    @discardableResult
    func drainHeadDirectly(reason: String) -> Bool {
        var freshest: Entry?
        var stale: [CMSampleBuffer] = []
        os_unfair_lock_lock(&lock)
        guard running, !queue.isEmpty else {
            os_unfair_lock_unlock(&lock)
            return false
        }
        // Present the FRESHEST frame (queue tail, hostPTS-ordered) and discard
        // the rest - a real-time stream wants the newest pixels, not a backlog.
        freshest = queue.removeLast()
        stale = queue.map { $0.sampleBuffer }
        queue.removeAll(keepingCapacity: true)
        // Re-seed so a rebuilt link starts clean.
        resetCadenceBaseLocked()
        liveness.starvedTickStreak = 0
        liveness.lastReleaseHostTime = CFAbsoluteTimeGetCurrent()
        os_unfair_lock_unlock(&lock)

        for _ in stale { stats.recordPresentationLateDrop() }
        log.warning(
            """
            FramePacer self-heal: direct-drain freshest frame \
            (\(reason, privacy: .public)) discarded=\(stale.count, privacy: .public)
            """)
        Diag.notice(
            "FramePacer self-heal: direct-drain freshest frame (\(reason)) discarded=\(stale.count)",
            "Stream.Pacer")
        OSSignposter.render.emitEvent("PacerDirectDrain", "discarded=\(stale.count, privacy: .public)")
        guard let entry = freshest, let willPresent else { return false }
        let presented = willPresent(entry.sampleBuffer)
        if presented {
            // A drained frame IS a successful present - it must reset the
            // reject streak (the consecutive-only invariant the ladder's
            // 8-streak jitter-proofing rests on) and stamp the freshness
            // bookkeeping, same as every other present site.
            noteFramePresented(entry.sampleBuffer)
        } else {
            // Even the watchdog's direct drain died at the renderer - strong
            // confirmation for the reject-streak verdict (noteGateReleaseRejected).
            noteGateReleaseRejected()
        }
        return presented
    }

    /// Collapse the FIFO to ONLY its freshest frame WITHOUT presenting anything.
    /// Used while presentation is intentionally suppressed (window backgrounded /
    /// occluded): the link isn't releasing, so without this the queue would grow
    /// to the cap and overflow-count every submit. Keeping exactly the newest
    /// frame means an instant resume has the latest pixels ready while the rest
    /// of the stale backlog is dropped. The dropped frames count as benign
    /// late-drops (telemetry stays measurable); no IDR is requested. Returns the
    /// number of stale frames discarded. Distinct from `drainHeadDirectly`, which
    /// PRESENTS the freshest frame (wrong while suppressed - nothing should hit a
    /// hidden layer) and from `clearQueue`, which empties it entirely.
    @discardableResult
    func dropToNewest(reason: String) -> Int {
        os_unfair_lock_lock(&lock)
        guard running, queue.count > 1 else {
            os_unfair_lock_unlock(&lock)
            return 0
        }
        let newest = queue.removeLast()
        let discarded = queue.count
        queue.removeAll(keepingCapacity: true)
        queue.append(newest)
        os_unfair_lock_unlock(&lock)

        for _ in 0..<discarded { stats.recordPresentationLateDrop() }
        log.info("FramePacer drop-to-newest (\(reason, privacy: .public)) discarded=\(discarded, privacy: .public)")
        OSSignposter.render.emitEvent("PacerDropToNewest", "discarded=\(discarded, privacy: .public)")
        return discarded
    }

    /// Empty the FIFO entirely and re-seed the cadence base so the next tick
    /// releases cleanly. Used on the suppressed→shown transition (refocus): the
    /// stale backlog from the suppressed period is dropped so the present path
    /// repaints from the fresh IDR the caller requests rather than draining old
    /// frames first. Dropped frames count as benign late-drops. Distinct from
    /// `stop()` (which also invalidates the link / tears the pacer down) - this
    /// keeps the pacer live, only the queue is cleared.
    @discardableResult
    func clearQueue(reason: String) -> Int {
        os_unfair_lock_lock(&lock)
        guard running else {
            os_unfair_lock_unlock(&lock)
            return 0
        }
        let discarded = queue.count
        queue.removeAll(keepingCapacity: true)
        resetCadenceBaseLocked()
        liveness.starvedTickStreak = 0
        os_unfair_lock_unlock(&lock)

        for _ in 0..<discarded { stats.recordPresentationLateDrop() }
        log.info("FramePacer clear-queue (\(reason, privacy: .public)) discarded=\(discarded, privacy: .public)")
        OSSignposter.render.emitEvent("PacerClearQueue", "discarded=\(discarded, privacy: .public)")
        return discarded
    }

    /// The frozen values a starved / self-heal beat logs after unlocking. `*Ms`
    /// fields are already in milliseconds.
    struct StarvationSnapshot {
        let streak: Int
        let depth: Int
        let sinceLastMs: Double
        let targetTimestamp: CFTimeInterval
        let lastPresent: CFTimeInterval
        let intervalMs: Double
    }

    /// Post-unlock starvation diagnostics: the negative-`sinceLast` warning (with the
    /// depth proving frames were queued) plus the self-heal breadcrumb. Side-effect
    /// only - kept off `releaseDueFrame`'s body (FramePacer+DueGate.swift).
    func emitStarvationDiagnostics(
        shouldLog: Bool, forcedSelfHeal: Bool, snapshot snap: StarvationSnapshot
    ) {
        if shouldLog {
            log.warning(
                // swiftlint:disable:next line_length
                "FramePacer starved: \(snap.streak, privacy: .public) ticks with frames queued (depth=\(snap.depth, privacy: .public)) and nothing released - sinceLast=\(snap.sinceLastMs, privacy: .public)ms targetTimestamp=\(snap.targetTimestamp, privacy: .public) lastPresentMediaTime=\(snap.lastPresent, privacy: .public) streamInterval=\(snap.intervalMs, privacy: .public)ms")
            OSSignposter.render.emitEvent(
                "PacerStarved",
                "depth=\(snap.depth, privacy: .public) sinceLastMs=\(snap.sinceLastMs, privacy: .public)")
        }
        if forcedSelfHeal {
            log.warning("FramePacer self-heal: forcing release after starvation (re-seeded cadence base)")
            OSSignposter.render.emitEvent("PacerForceRelease", "depth=\(snap.depth, privacy: .public)")
        }
    }
}
