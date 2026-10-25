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

import AVFoundation
import CoreMedia
import QuartzCore
import os

extension FramePacer {
    package typealias LivenessSnapshot = PacerLivenessSnapshot
    package typealias RefreshWindowSnapshot = PacerRefreshWindowSnapshot

    /// Match the present watchdog's freeze window even when refusals leave the queue empty.
    package static let rendererRefusalWindowSeconds: Double = 0.25

    // MARK: - Snapshot types

    // MARK: - Link bind (the single path start / screen-change / rebuild use)

    @MainActor
    func installLink(on display: PacerDisplay) {
        // Reset before binding because a new display can use a discontinuous timebase.
        lock.lock()
        resetCadenceBaseLocked()
        bindingGeneration &+= 1
        displayBound = false
        let generation = bindingGeneration
        lock.unlock()

        let proxy = DisplayLinkProxy { [weak self] link in
            self?.handleTick(link, generation: generation)
        }
        boundScreenSignature = nil
        guard let link = display.makeLink(proxy, #selector(DisplayLinkProxy.tick(_:))) else {
            pacingQueue.async { [weak self] in self?.reconcileDeficitTimer() }
            return
        }
        lock.lock()
        displayBound = true
        lock.unlock()
        // Static-layer callback throttling once late-dropped 38% of frames; fixed screens retain
        // the full grid. Variable screens follow content, with deficit recovery for ignored hints.
        // Only a callback hint changes; display modes and the user's refresh setting stay untouched.
        let screen = display.screen()
        let panelMax = screen.maximumHz
        let panelMinimum = screen.minimumHz
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
        if display.tickOffMain() {
            let tickThread = pacerTickThread ?? PacerTickThread(prepareThread: display.prepareTickThread)
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
        pacingQueue.async { [weak self] in self?.reconcileDeficitTimer() }
        // Seed the bound-screen signature so `screenDidChange` can distinguish
        // a REAL move/mode change from ProMotion VRR-housekeeping notifications.
        self.boundScreenSignature = Self.screenSignature(for: screen)
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
        guard isRunning, let display = boundDisplay else { return }
        // ProMotion housekeeping once caused 785 rebinds in 12 minutes, resetting cadence each time.
        // Rebind only for identity, scale or capability changes; a fixed/variable switch is material.
        // The watchdog still rebuilds unconditionally when an unchanged link silently stops.
        let signature = Self.screenSignature(for: display.screen())
        guard displayLink == nil || signature != boundScreenSignature else { return }
        log.info("FramePacer rebinding display link after screen change")
        Diag.info("FramePacer rebinding display link after screen change", "Stream.Pacer")
        displayLink?.invalidate()
        displayLink = nil
        installLink(on: display)
    }

    /// Capabilities, not realized callback rates, distinguish mode changes from VRR housekeeping.
    @MainActor
    static func screenSignature(for screen: PacerScreen) -> String {
        guard screen.identity != "none" else { return "none" }
        return screenSignature(displayID: screen.identity, maximumHz: screen.maximumHz,
                               minimumHz: screen.minimumHz, scale: screen.scale)
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
        guard isRunning, let display = boundDisplay else { return }
        log.warning("FramePacer self-heal: rebuilding display link (\(reason, privacy: .public))")
        Diag.notice("FramePacer self-heal: rebuilding display link (\(reason))", "Stream.Pacer")
        #if os(macOS) || GLIMMER_DIAGNOSTICS
        OSSignposter.render.emitEvent("PacerLinkRebuild", "reason=\(reason, privacy: .public)")
        #endif
        displayLink?.invalidate()
        displayLink = nil
        installLink(on: display)
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
        #if os(macOS) || GLIMMER_DIAGNOSTICS
        OSSignposter.render.emitEvent("PacerForceReleaseNextTick", "depth=\(depth, privacy: .public)")
        #endif
        return depth
    }

    /// When ticks stop, bypass the due gate on the pacing queue so recovery
    /// cannot race a deficit beat's renderer enqueue. Keep the freshest frame
    /// visible while the link rebuilds.
    func drainHeadDirectly(reason: String) {
        lock.lock()
        let generation = bindingGeneration
        lock.unlock()
        pacingQueue.async { [weak self] in self?.drainHeadDirectlyOnQueue(reason: reason, generation: generation) }
    }

    private func drainHeadDirectlyOnQueue(reason: String, generation: UInt64) {
        var freshest: Entry?
        var stale: [CMSampleBuffer] = []
        lock.lock()
        guard running, bindingGeneration == generation, !queue.isEmpty else {
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

        recordPresentationDiscards(stale, reason: .recovery)
        log.warning(
            """
            FramePacer self-heal: direct-drain freshest frame \
            (\(reason, privacy: .public)) discarded=\(stale.count, privacy: .public)
            """)
        Diag.notice(
            "FramePacer self-heal: direct-drain freshest frame (\(reason)) discarded=\(stale.count)",
            "Stream.Pacer")
        #if os(macOS) || GLIMMER_DIAGNOSTICS
        OSSignposter.render.emitEvent("PacerDirectDrain", "discarded=\(stale.count, privacy: .public)")
        #endif
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
        let discardedFrames = queue.map(\.sampleBuffer)
        let discardReason: FrameInstrumentation.PacerDiscardReason = presentSuppressed ? .suppressed : .recovery
        queue.removeAll(keepingCapacity: true)
        queue.append(newest)
        lock.unlock()

        recordPresentationDiscards(discardedFrames, reason: discardReason)
        log.info("FramePacer drop-to-newest (\(reason, privacy: .public)) discarded=\(discarded, privacy: .public)")
        #if os(macOS) || GLIMMER_DIAGNOSTICS
        OSSignposter.render.emitEvent("PacerDropToNewest", "discarded=\(discarded, privacy: .public)")
        #endif
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
        presentationGeneration &+= 1
        let discardedFrames = queue.map(\.sampleBuffer) + retireSubmitReleaseLocked()
        let discarded = discardedFrames.count
        queue.removeAll(keepingCapacity: true)
        resetCadenceBaseLocked()
        // Drop the last-presented frame too, so a governor repaint after this flush
        // (e.g. a format/discontinuity change) can't re-commit a stale old-format frame.
        tickDeficit.lastPresentedSampleBuffer = nil
        liveness.starvedTickStreak = 0
        lock.unlock()

        recordPresentationDiscards(discardedFrames, reason: .cleared)
        log.info("FramePacer clear-queue (\(reason, privacy: .public)) discarded=\(discarded, privacy: .public)")
        #if os(macOS) || GLIMMER_DIAGNOSTICS
        OSSignposter.render.emitEvent("PacerClearQueue", "discarded=\(discarded, privacy: .public)")
        #endif
        return discarded
    }

    /// Finish any in-flight release before flushing, and retire old handoffs at the same boundary.
    @discardableResult
    func clearQueue(reason: String, beforeNextPresentation: () -> Void) -> Int {
        assertLockNotHeld()
        if DispatchQueue.getSpecific(key: pacingQueueKey) != nil {
            let discarded = clearQueue(reason: reason)
            beforeNextPresentation()
            return discarded
        }
        return pacingQueue.sync {
            let discarded = self.clearQueue(reason: reason)
            beforeNextPresentation()
            return discarded
        }
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
            #if os(macOS) || GLIMMER_DIAGNOSTICS
            OSSignposter.render.emitEvent(
                "PacerStarved",
                "depth=\(snap.depth, privacy: .public) sinceLastMs=\(snap.sinceLastMs, privacy: .public)")
            #endif
        }
        if forcedSelfHeal {
            log.warning("FramePacer self-heal: forcing release after starvation (re-seeded cadence base)")
            #if os(macOS) || GLIMMER_DIAGNOSTICS
            OSSignposter.render.emitEvent("PacerForceRelease", "depth=\(snap.depth, privacy: .public)")
            #endif
        }
    }
}
