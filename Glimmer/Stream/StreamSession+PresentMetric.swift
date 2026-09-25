//
//  StreamSession+PresentMetric.swift
//

import Foundation
import os

extension StreamSession {

    /// Keep the two-second jitter update while limiting persisted healthy metrics.
    func startPresentMetricTimer() async {
        let dec = videoDecoder
        await MainActor.run {
            self.presentMetricTimer?.invalidate()
            self.prevMetricTotalTicks = 0
            self.prevMetricTotalReleases = 0
            self.prevMetricTime = CFAbsoluteTimeGetCurrent()
            self.lastPresentMetricNoticeTime = self.prevMetricTime
            let timer = Timer.scheduledTimer(
                withTimeInterval: 2.0, repeats: true
            ) { [weak self, weak dec] _ in
                MainActor.assumeIsolated {
                    guard let self, let dec else { return }
                    self.emitPresentMetric(dec: dec)
                }
            }
            timer.tolerance = 0.2
            self.presentMetricTimer = timer
        }
    }

    @MainActor
    private func emitPresentMetric(dec: VideoDecoder) {
        let now = CFAbsoluteTimeGetCurrent()
        let decodeIdle = dec.secondsSinceLastDecodedFrame()
        // Only emit once frames have started flowing, so a quiet handshake
        // window doesn't spam the log.
        guard decodeIdle.isFinite else { return }

        // Forward the latest SMOOTHED RFC-3550 reorder jitter to the pacer on this
        // ~2s cadence (the same cadence the RTP receive path refreshes the shared
        // gauge on), so the adaptive buffer grows ONLY for SUSTAINED MEASURED
        // jitter (lossy wifi) and rests at depth 1 on a clean link (0.09ms wired).
        dec.pacingNoteMeasuredJitter(TelemetryCounters.shared.recvJitterMs)
        guard !dec.presentSuppressed else { return }
        // sincePresent is the MODE-AGNOSTIC present clock - meaningful in BOTH
        // paced and direct mode, so the metric line shows how long since a frame
        // reached the screen even when the pacer is down.
        let sincePresent = dec.secondsSinceLastPresentedFrame()
        guard let live = dec.pacingLiveness() else {
            // Direct-enqueue fallback path - report decode + present liveness.
            let level = Self.presentMetricNeedsNotice(
                sinceTick: 0, sinceRelease: 0, sincePresent: sincePresent,
                decodeIdle: decodeIdle, sinceNotice: now - lastPresentMetricNoticeTime
            ) ? OSLogType.default : .debug
            if level == .default { lastPresentMetricNoticeTime = now }
            self.log.log(level: level, """
                PRESENT METRIC pacer=direct decodeIdle=\(decodeIdle * 1000, format: .fixed(precision: 1), privacy: .public)ms \
                sincePresent=\(sincePresent * 1000, format: .fixed(precision: 1), privacy: .public)ms
                """)
            return
        }
        let dt = max(0.001, now - self.prevMetricTime)
        let ticksPerSec = Double(live.totalTicks &- self.prevMetricTotalTicks) / dt
        let presentsPerSec = Double(live.totalReleases &- self.prevMetricTotalReleases) / dt
        self.prevMetricTotalTicks = live.totalTicks
        self.prevMetricTotalReleases = live.totalReleases
        self.prevMetricTime = now
        let level = Self.presentMetricNeedsNotice(
            sinceTick: live.secondsSinceLastTick, sinceRelease: live.secondsSinceLastRelease,
            sincePresent: sincePresent, decodeIdle: decodeIdle,
            sinceNotice: now - lastPresentMetricNoticeTime
        ) ? OSLogType.default : .debug
        if level == .default { lastPresentMetricNoticeTime = now }
        self.log.log(level: level, """
            PRESENT METRIC ticks/s=\(ticksPerSec, format: .fixed(precision: 1), privacy: .public) \
            presents/s=\(presentsPerSec, format: .fixed(precision: 1), privacy: .public) \
            sinceTick=\(live.secondsSinceLastTick * 1000, format: .fixed(precision: 1), privacy: .public)ms \
            sinceRelease=\(live.secondsSinceLastRelease * 1000, format: .fixed(precision: 1), privacy: .public)ms \
            depth=\(live.depth, privacy: .public) targetDepth=\(live.adaptiveTargetDepth, privacy: .public) \
            streamInterval=\(live.streamFrameIntervalSeconds * 1000, format: .fixed(precision: 2), privacy: .public)ms \
            decodeIdle=\(decodeIdle * 1000, format: .fixed(precision: 1), privacy: .public)ms
            """)
    }

    static func presentMetricNeedsNotice(
        sinceTick: Double, sinceRelease: Double, sincePresent: Double,
        decodeIdle: Double, sinceNotice: Double
    ) -> Bool {
        sinceTick >= presentLinkDeadThreshold
            || sinceRelease >= presentStallThreshold
            || sincePresent >= presentStallThreshold
            || decodeIdle >= presentStallThreshold
            || sinceNotice >= 60
    }
}
