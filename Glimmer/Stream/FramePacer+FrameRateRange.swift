// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io
// SPDX-FileCopyrightText: Moonlight Game Streaming Project contributors

import AppKit
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

        init(appliedAt: Double = -.infinity, preferredHz: Double = .nan) {
            self.appliedAt = appliedAt
            self.preferredHz = preferredHz
        }

        func rangeForRebind(configuredInterval: Double, panelMaxHz: Double,
                            variableMinimumHz: Double?) -> CAFrameRateRange {
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
            if range.maximum != current.maximum
                || (range.minimum != current.minimum && range.preferred == current.preferred) {
                movedSince = nil
                return true
            }
            let preferred = Double(range.preferred ?? 0)
            guard let contentSince, now.isFinite, preferredHz.isFinite,
                  abs(preferred - preferredHz) > preferredHz * 0.1 else {
                movedSince = nil
                return false
            }
            // A different destination restarts the dwell; ordinary whole-Hz jitter does not.
            if movedSince == nil || abs(preferred - candidateHz) > candidateHz * 0.1
                || (preferred - preferredHz) * (candidateHz - preferredHz) <= 0 {
                movedSince = now
                candidateHz = preferred
            }
            guard let movedSince, now - max(movedSince, contentSince) >= 2 else { return false }
            self.movedSince = nil
            return true
        }
    }

    @MainActor
    func reapplyPreferredRangeIfNeeded() {
        guard let link = displayLink, let view = boundView else { return }
        replayLinkInstalledBreadcrumbIfNeeded(link: link, view: view)
        let panelMax = Self.panelMaxHz(for: view)
        let panelMinimum = Self.variableMinimumHz(for: view)
        let now = CACurrentMediaTime()
        lock.lock()
        let interval = presentationIntervalLocked()
        let measuredHz = tickDeficit.measuredTicksPerSecond
        let suppressed = presentSuppressed
        let contentSince = suppressed ? nil : rateHintSamples.eligibleSince(now: now, interval: interval)
        lock.unlock()
        guard !suppressed else {
            rateHint = RateHint(appliedAt: rateHint.appliedAt, preferredHz: rateHint.preferredHz)
            return
        }
        let followsContent = panelMinimum != nil
            && rateHint.followsContent(now: now, measuredHz: measuredHz, contentHz: 1 / interval)
        let fallbackInterval = panelMinimum != nil ? 1 / panelMax : configuredFrameIntervalSeconds
        let range = Self.preferredRange(
            forStreamIntervalSeconds: followsContent ? interval : fallbackInterval,
            panelMaxHz: panelMax, variableMinimumHz: followsContent ? panelMinimum : nil)
        if rateHint.needsUpdate(to: range, current: link.preferredFrameRateRange,
                                now: now, contentSince: panelMinimum == nil ? -.infinity : contentSince) {
            applyPreferredRange(range, to: link, variable: followsContent)
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
    func applyPreferredRange(_ range: CAFrameRateRange, to link: CADisplayLink, variable: Bool) {
        link.preferredFrameRateRange = range
        rateHint.appliedAt = CACurrentMediaTime()
        rateHint.preferredHz = Double(range.preferred ?? 0)
        lock.lock()
        tickDeficit.pinnedFloorHz = Double(range.minimum)
        variableRefreshEnabled = variable
        lock.unlock()
    }

    /// Install precedes the session file sink. Replay once per sink so the initial range is greppable.
    @MainActor private static var lastReplayedLogSinkID: ObjectIdentifier?
    @MainActor
    private func replayLinkInstalledBreadcrumbIfNeeded(link: CADisplayLink, view: NSView) {
        guard let sink = SessionLogFileSink.shared else { return }
        let sinkID = ObjectIdentifier(sink)
        guard Self.lastReplayedLogSinkID != sinkID else { return }
        Self.lastReplayedLogSinkID = sinkID
        let range = link.preferredFrameRateRange
        Diag.info(
            "FramePacer link installed - floor=\(Double(range.minimum))Hz "
            + "preferred=\(Double(range.preferred ?? 0))Hz max=\(Double(range.maximum))Hz "
            + "(panelMax=\(Self.panelMaxHz(for: view))Hz) [replayed at session-log start]",
            "Stream.Pacer")
    }

    @MainActor
    static func panelMaxHz(for view: NSView) -> Double {
        let maxFps = view.window?.screen?.maximumFramesPerSecond
            ?? NSScreen.main?.maximumFramesPerSecond ?? 60
        return maxFps > 0 ? Double(maxFps) : 60.0
    }

    @MainActor
    static func variableMinimumHz(for view: NSView) -> Double? {
        guard let screen = view.window?.screen ?? NSScreen.main else { return nil }
        return variableMinimumHz(minimumInterval: screen.minimumRefreshInterval,
                                 maximumInterval: screen.maximumRefreshInterval,
                                 granularity: screen.displayUpdateGranularity)
    }

    /// A variable-capable panel can still be in a fixed mode. Its update granularity tells those apart.
    static func variableMinimumHz(minimumInterval: Double, maximumInterval: Double,
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
        let panel = panelMaxHz.isFinite && panelMaxHz > 0 ? panelMaxHz : 60.0
        let stream = 1 / clampFrameInterval(intervalSeconds)
        if let minimum = variableMinimumHz, minimum.isFinite, minimum > 0, minimum < panel {
            // Deep VRR excursions change panel brightness, especially on fast G-Sync-compatible displays.
            // Stay in the top quarter of the range, with a 120 Hz floor where the panel supports it.
            // Clamp to the panel maximum so slower displays still receive a valid hint.
            let floor = min(panel, max(minimum, 120, panel * 0.75))
            return CAFrameRateRange(minimum: Float(floor), maximum: Float(panel),
                                    preferred: Float(min(max(stream.rounded(), floor.rounded(.up)), panel)))
        }
        return CAFrameRateRange(minimum: Float(min(stream, panel)), maximum: Float(panel), preferred: Float(panel))
    }

    static func releaseInterval(variable: Bool, target: Double, timestamp: Double, nominal: Double) -> Double {
        let interval = target - timestamp
        return variable && interval.isFinite && interval > 0 && interval <= maxRealizedTickDeltaSeconds
            ? interval : nominal
    }
}
