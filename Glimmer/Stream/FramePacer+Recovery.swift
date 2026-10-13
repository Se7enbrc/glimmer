// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// SPDX-FileCopyrightText: Moonlight Game Streaming Project contributors

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

import GlimmerEngine
import AppKit
import AVFoundation
import CoreMedia
import QuartzCore
import os

extension FramePacer {
    typealias LivenessSnapshot = PacerLivenessSnapshot
    typealias RefreshWindowSnapshot = PacerRefreshWindowSnapshot

    /// Match the present watchdog's freeze window even when refusals leave the queue empty.
    static let rendererRefusalWindowSeconds: Double = 0.25

    // MARK: - Snapshot types

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
        lock.lock()
        resetCadenceBaseLocked()
        lock.unlock()

        let proxy = DisplayLinkProxy { [weak self] link in
            self?.handleTick(link)
        }
        let link = view.displayLink(target: proxy, selector: #selector(DisplayLinkProxy.tick(_:)))
        // Static-layer callback throttling once late-dropped 38% of frames; fixed screens retain
        // the full grid. Variable screens follow content, with deficit recovery for ignored hints.
        // Only a callback hint changes; display modes and the user's refresh setting stay untouched.
        let panelMax = Self.panelMaxHz(for: view)
        let panelMinimum = Self.variableMinimumHz(for: view)
        configurePreferredRange(link: link, panelMax: panelMax, panelMinimum: panelMinimum)
        let range = link.preferredFrameRateRange
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
            // Only route onto the tick thread once its loop is CONFIRMED running;
            // otherwise add(_:) could block the main actor on an unstarted loop.
            // Fall back to the main run loop - never to an unconfirmed perform().
            if tickThread.start() {
                tickThread.add(link)
            } else {
                link.add(to: .main, forMode: .common)
            }
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
            // A zero range means presentation is suppressed and macOS owns the rate.
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
            lock.lock(); defer { lock.unlock() }
            return running
        }()
        guard isRunning, let view = boundView else { return }
        // ProMotion housekeeping once caused 785 rebinds in 12 minutes, resetting cadence each time.
        // Rebind only for identity, scale or capability changes; a fixed/variable switch is material.
        // The watchdog still rebuilds unconditionally when an unchanged link silently stops.
        let signature = Self.screenSignature(for: view)
        guard signature != boundScreenSignature else { return }
        log.info("FramePacer rebinding display link after screen change")
        Diag.info("FramePacer rebinding display link after screen change", "Stream.Pacer")
        displayLink?.invalidate()
        displayLink = nil
        installLink(on: view)
    }

    /// Capabilities, not realized callback rates, distinguish mode changes from VRR housekeeping.
    @MainActor
    static func screenSignature(for view: NSView) -> String {
        guard let screen = view.window?.screen else { return "none" }
        let displayID = screen.cgDirectDisplayID.map { String($0) } ?? "none"
        return screenSignature(displayID: displayID, maximumHz: panelMaxHz(for: view),
                               minimumHz: variableMinimumHz(for: view), scale: screen.backingScaleFactor)
    }

    static func screenSignature(displayID: String, maximumHz: Double, minimumHz: Double?, scale: Double) -> String {
        "\(displayID)|\(maximumHz)|\(minimumHz.map { String($0) } ?? "fixed")|\(scale)"
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
            lock.lock(); defer { lock.unlock() }
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
        lock.lock(); defer { lock.unlock() }
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

    /// Read liveness and advance rate windows even when display ticks stop.
    /// An explicit clock keeps boundary regressions deterministic without sleeping.
    func livenessSnapshot(at now: CFAbsoluteTime = CFAbsoluteTimeGetCurrent()) -> LivenessSnapshot {
        lock.lock()
        let events = serviceTickDeficitLocked(now: now)
        let sinceTick = liveness.lastTickHostTime.isFinite ? now - liveness.lastTickHostTime : .infinity
        let sinceRelease = liveness.lastReleaseHostTime.isFinite ? now - liveness.lastReleaseHostTime : .infinity
        let nonEmptyFor = queue.isEmpty ? 0 : now - liveness.queueNonEmptySince
        let snapshot = LivenessSnapshot(
            secondsSinceLastTick: sinceTick,
            secondsSinceLastRelease: sinceRelease,
            depth: queue.count,
            secondsQueueNonEmpty: nonEmptyFor,
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
            presentRejectStreak: liveness.presentRejectStreak,
            rendererRefusalSeconds: liveness.lastRejectHostTime - liveness.firstRejectHostTime,
            secondsSinceLastReject: now - liveness.lastRejectHostTime)
        lock.unlock()
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
        forceReleaseNextTick(reason: reason, linkTarget: displayLink?.targetTimestamp ?? .nan)
    }

    /// The poke on the live link's `targetTimestamp` (NaN without a link).
    @discardableResult
    func forceReleaseNextTick(reason: String, linkTarget target: CFTimeInterval) -> Int {
        lock.lock()
        let depth = queue.count
        anchorCadenceBaseOnGridLocked(targetTimestamp: target)
        liveness.starvedTickStreak = 0
        lock.unlock()
        log.warning("FramePacer self-heal: force-release-next-tick (\(reason, privacy: .public)) depth=\(depth, privacy: .public)")
        Diag.notice(
            "FramePacer self-heal: force-release-next-tick (\(reason)) depth=\(depth)",
            "Stream.Pacer")
        OSSignposter.render.emitEvent("PacerForceReleaseNextTick", "depth=\(depth, privacy: .public)")
        return depth
    }

    /// When ticks stop, bypass the due gate on the pacing queue so recovery
    /// cannot race a deficit beat's renderer enqueue. Keep the freshest frame
    /// visible while the link rebuilds.
    func drainHeadDirectly(reason: String) {
        pacingQueue.async { [weak self] in self?.drainHeadDirectlyOnQueue(reason: reason) }
    }

    private func drainHeadDirectlyOnQueue(reason: String) {
        var freshest: Entry?
        var stale: [CMSampleBuffer] = []
        lock.lock()
        guard running, !queue.isEmpty else {
            lock.unlock()
            return
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
        lock.unlock()

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
        guard let entry = freshest, let willPresent else { return }
        let presented = willPresent(entry.sampleBuffer)
        if presented {
            // Reset the consecutive reject streak and freshness clocks on success,
            // so the watchdog cannot escalate from failures this drain recovered.
            noteFramePresented(entry.sampleBuffer)
        } else {
            // Even the watchdog's direct drain died at the renderer - strong
            // confirmation for the reject-streak verdict (noteGateReleaseRejected).
            noteGateReleaseRejected()
        }
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
        lock.lock()
        guard running, queue.count > 1 else {
            lock.unlock()
            return 0
        }
        let newest = queue.removeLast()
        let discarded = queue.count
        queue.removeAll(keepingCapacity: true)
        queue.append(newest)
        lock.unlock()

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
        lock.lock()
        guard running else {
            lock.unlock()
            return 0
        }
        rateHintSamples = RateHintSamples()
        let discarded = queue.count
        queue.removeAll(keepingCapacity: true)
        resetCadenceBaseLocked()
        // Drop the last-presented frame too, so a governor repaint after this flush
        // (e.g. a format/discontinuity change) can't re-commit a stale old-format frame.
        tickDeficit.lastPresentedSampleBuffer = nil
        liveness.starvedTickStreak = 0
        lock.unlock()

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
            log.warning("""
                FramePacer starved: \(snap.streak, privacy: .public) ticks with frames queued \
                (depth=\(snap.depth, privacy: .public)) and nothing released - sinceLast=\(snap.sinceLastMs, privacy: .public)ms \
                targetTimestamp=\(snap.targetTimestamp, privacy: .public) \
                lastPresentMediaTime=\(snap.lastPresent, privacy: .public) streamInterval=\(snap.intervalMs, privacy: .public)ms
                """)
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
