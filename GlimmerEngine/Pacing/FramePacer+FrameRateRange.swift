// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io
// SPDX-FileCopyrightText: Moonlight Game Streaming Project contributors

import QuartzCore

extension FramePacer {
    struct RateHintLog {
        private var preferredHz: Double?
        private var variable: Bool?

        init() {}

        mutating func shouldLog(preferred: Double, variable: Bool, now: Double) -> Bool {
            guard preferred.isFinite, now.isFinite,
                  preferredHz != preferred || self.variable != variable else { return false }
            preferredHz = preferred
            self.variable = variable
            return true
        }
    }

    /// Delivery interruptions restart hint observation without changing the presentation cadence.
    struct RateHintSamples {
        private var lastArrival = Double.nan
        private var lastPTS = Double.nan
        private var continuousSince = Double.nan

        init() {}

        mutating func observe(pts: Double, now: Double, interval: Double) {
            let arrivalDelta = now - lastArrival
            let ptsDelta = pts - lastPTS
            if !continuousSince.isFinite || !ptsDelta.isFinite || ptsDelta <= 0 || ptsDelta > interval * 4
                || !arrivalDelta.isFinite || arrivalDelta < interval * 0.25 || arrivalDelta > interval * 4 {
                continuousSince = now
            }
            lastArrival = now
            lastPTS = pts
        }

        func eligibleSince(now: Double, interval: Double) -> Double? {
            guard continuousSince.isFinite, now >= lastArrival,
                  now - lastArrival <= interval * 4 else { return nil }
            return continuousSince
        }
    }

    /// Hints are advisory. Retrying after a short fallback lets a recovering governor follow content again.
    struct RateHint {
        var appliedAt = -Double.infinity
        var preferredHz = Double.nan
        var shortSince = Double.nan
        var fallbackUntil = -Double.infinity
        private var movedSince: Double?
        private var candidateHz = Double.nan
        private(set) var awaitingRestore = false

        init(appliedAt: Double = -.infinity, preferredHz: Double = .nan) {
            self.appliedAt = appliedAt
            self.preferredHz = preferredHz
        }

        mutating func releaseRequest() {
            self = RateHint(appliedAt: appliedAt, preferredHz: preferredHz)
            awaitingRestore = true
        }

        func rangeForRebind(configuredInterval: Double, panelMaxHz: Double,
                            variableMinimumHz: Double?) -> CAFrameRateRange {
            guard !awaitingRestore else { return .default }
            // Rebinding after a gap must not adopt a transiently low content estimate.
            let heldInterval = preferredHz.isFinite ? 1 / preferredHz : configuredInterval
            return FramePacer.preferredRange(
                forStreamIntervalSeconds: variableMinimumHz != nil ? heldInterval : configuredInterval,
                panelMaxHz: panelMaxHz, variableMinimumHz: variableMinimumHz)
        }

        mutating func followsContent(now: Double, measuredHz: Double, contentHz: Double) -> Bool {
            guard now >= fallbackUntil else { return false }
            guard now - appliedAt >= 0.5 else { return true }
            if measuredHz.isFinite, measuredHz < min(preferredHz, contentHz) * 0.9 {
                if !shortSince.isFinite { shortSince = now }
                if now - shortSince >= 1 {
                    fallbackUntil = now + 5
                    shortSince = .nan
                    return false
                }
            } else {
                shortSince = .nan
            }
            return true
        }

        mutating func needsUpdate(to range: CAFrameRateRange, current: CAFrameRateRange,
                                  now: Double, contentSince: Double? = -.infinity) -> Bool {
            if !awaitingRestore && (range.maximum != current.maximum
                || (range.minimum != current.minimum && range.preferred == current.preferred)) {
                movedSince = nil
                return true
            }
            let preferred = Double(range.preferred ?? 0)
            guard let contentSince, now.isFinite,
                  awaitingRestore || (preferredHz.isFinite && abs(preferred - preferredHz) > preferredHz * 0.1) else {
                movedSince = nil
                return false
            }
            // A different destination restarts the dwell; ordinary cadence jitter does not.
            if movedSince == nil || abs(preferred - candidateHz) > candidateHz * 0.1
                || (!awaitingRestore && (preferred - preferredHz) * (candidateHz - preferredHz) <= 0) {
                movedSince = now
                candidateHz = preferred
            }
            guard let movedSince, now - max(movedSince, contentSince) >= 2 else { return false }
            self.movedSince = nil
            awaitingRestore = false
            return true
        }
    }

    @MainActor
    func reapplyPreferredRangeIfNeeded() {
        guard let link = displayLink, let display = boundDisplay else { return }
        let screen = display.screen()
        replayLinkInstalledBreadcrumbIfNeeded(link: link, panelMax: screen.maximumHz)
        let panelMax = screen.maximumHz
        let panelMinimum = screen.minimumHz
        updatePreferredRange(link: link, panelMax: panelMax, panelMinimum: panelMinimum)
    }

    @MainActor
    func updatePreferredRange(link: CADisplayLink, panelMax: Double, panelMinimum: Double?,
                              now: Double = CACurrentMediaTime()) {
        lock.lock()
        let interval = presentationIntervalLocked()
        let measuredHz = tickDeficit.measuredTicksPerSecond
        let suppressed = presentSuppressed
        let contentSince = suppressed ? nil : rateHintSamples.eligibleSince(now: now, interval: interval)
        lock.unlock()
        guard !suppressed else {
            releasePreferredRange(to: link)
            return
        }
        let followsContent = panelMinimum != nil
            && rateHint.followsContent(now: now, measuredHz: measuredHz, contentHz: 1 / interval)
        let fallbackInterval = panelMinimum != nil ? 1 / panelMax : configuredFrameIntervalSeconds
        let range = Self.preferredRange(
            forStreamIntervalSeconds: followsContent ? interval : fallbackInterval,
            panelMaxHz: panelMax, variableMinimumHz: followsContent ? panelMinimum : nil)
        if rateHint.needsUpdate(to: range, current: link.preferredFrameRateRange,
                                now: now, contentSince: panelMinimum == nil && !rateHint.awaitingRestore
                                    ? -.infinity : contentSince) {
            applyPreferredRange(range, to: link, variable: followsContent, now: now)
        }
        lock.lock()
        let variable = variableRefreshEnabled
        lock.unlock()
        let applied = link.preferredFrameRateRange
        guard rateHintLog.shouldLog(preferred: Double(applied.preferred ?? 0),
                                    variable: variable, now: now) else { return }
        Diag.info(
            "FramePacer rate hint - floor=\(Double(applied.minimum))Hz "
            + "preferred=\(Double(applied.preferred ?? 0))Hz max=\(Double(applied.maximum))Hz "
            + "content=\(1 / interval)Hz variable=\(variable)", "Stream.Pacer")
    }

    /// Only a callback hint is written. Display modes and the user's refresh setting remain owned by macOS.
    @MainActor
    func applyPreferredRange(_ range: CAFrameRateRange, to link: CADisplayLink, variable: Bool,
                             now: Double = CACurrentMediaTime()) {
        link.preferredFrameRateRange = range
        rateHint.appliedAt = now
        rateHint.preferredHz = Double(range.preferred ?? 0)
        lock.lock()
        tickDeficit.pinnedFloorHz = Double(range.minimum)
        variableRefreshEnabled = variable
        lock.unlock()
    }

    /// Clear the request on the suppression edge, even if the hidden link stops ticking.
    @MainActor
    func releasePreferredRangeIfSuppressed() {
        lock.lock()
        let suppressed = presentSuppressed
        lock.unlock()
        guard suppressed, let link = displayLink else { return }
        releasePreferredRange(to: link)
    }

    @MainActor
    private func releasePreferredRange(to link: CADisplayLink) {
        let changed = !rateHint.awaitingRestore
        rateHint.releaseRequest()
        link.preferredFrameRateRange = .default
        lock.lock()
        tickDeficit.pinnedFloorHz = 0
        variableRefreshEnabled = false
        lock.unlock()
        if changed { Diag.info("FramePacer rate hint released - presentation suppressed", "Stream.Pacer") }
    }

    @MainActor
    func configurePreferredRange(link: CADisplayLink, panelMax: Double, panelMinimum: Double?) {
        lock.lock()
        let suppressed = presentSuppressed
        lock.unlock()
        if suppressed {
            releasePreferredRange(to: link)
            return
        }
        let range = rateHint.rangeForRebind(configuredInterval: configuredFrameIntervalSeconds,
                                            panelMaxHz: panelMax, variableMinimumHz: panelMinimum)
        // A hidden rebind or a move during resume must not bypass the fresh-content dwell.
        if rateHint.awaitingRestore {
            link.preferredFrameRateRange = .default
        } else {
            rateHint = RateHint()
            applyPreferredRange(range, to: link, variable: panelMinimum != nil)
        }
    }

    /// Install precedes the session file sink. Replay once per sink so the initial range is greppable.
    @MainActor private static var lastReplayedLogSinkID: ObjectIdentifier?
    @MainActor
    private func replayLinkInstalledBreadcrumbIfNeeded(link: CADisplayLink, panelMax: Double) {
        guard let sink = SessionLogFileSink.shared else { return }
        let sinkID = ObjectIdentifier(sink)
        guard Self.lastReplayedLogSinkID != sinkID else { return }
        Self.lastReplayedLogSinkID = sinkID
        let range = link.preferredFrameRateRange
        Diag.info(
            "FramePacer link installed - floor=\(Double(range.minimum))Hz "
            + "preferred=\(Double(range.preferred ?? 0))Hz max=\(Double(range.maximum))Hz "
            + "(panelMax=\(panelMax)Hz) [replayed at session-log start]",
            "Stream.Pacer")
    }

    package static func panelMaxHz(minimumInterval: Double, maximumFramesPerSecond: Int) -> Double {
        if minimumInterval.isFinite, minimumInterval > 0, (1 / minimumInterval).isFinite {
            return 1 / minimumInterval
        }
        return Double(max(0, maximumFramesPerSecond))
    }

    /// A variable-capable panel can still be in a fixed mode. Its update granularity tells those apart.
    package static func variableMinimumHz(minimumInterval: Double, maximumInterval: Double,
                                          granularity: Double) -> Double? {
        guard minimumInterval.isFinite, maximumInterval.isFinite, granularity.isFinite,
              minimumInterval > 0, maximumInterval > minimumInterval * 1.01,
              granularity >= 0, granularity < minimumInterval * 0.99 else { return nil }
        return 1 / maximumInterval
    }

    /// Fixed screens retain the full callback grid; variable screens may follow measured content.
    static func preferredRange(
        forStreamIntervalSeconds intervalSeconds: Double, panelMaxHz: Double,
        variableMinimumHz: Double? = nil
    ) -> CAFrameRateRange {
        guard panelMaxHz.isFinite, panelMaxHz > 0 else { return .default }
        let panel = panelMaxHz
        let stream = intervalSeconds.isFinite && intervalSeconds > 0 ? 1 / intervalSeconds : panel
        if let minimum = variableMinimumHz, minimum.isFinite, minimum > 0, minimum < panel {
            // Deep VRR excursions change panel brightness, especially on fast G-Sync-compatible displays.
            // Stay in the top quarter, clamped to this panel's reported range.
            let floor = min(panel, max(minimum, panel * 0.75))
            return CAFrameRateRange(minimum: Float(floor), maximum: Float(panel),
                                    preferred: Float(min(max(stream, floor), panel)))
        }
        return CAFrameRateRange(minimum: Float(min(stream, panel)), maximum: Float(panel), preferred: Float(panel))
    }

    static func releaseInterval(variable: Bool, target: Double, timestamp: Double, nominal: Double) -> Double {
        let interval = target - timestamp
        return variable && interval.isFinite && interval > 0 && interval <= maxRealizedTickDeltaSeconds
            ? interval : nominal
    }
}
