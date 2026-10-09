//
//  TelemetryConfigRowTests.swift
//
//  What a session's config event says about the stream and its bitrate ask, and
//  how the 1 Hz audio fields tell a blackout from the fold beat.
//

import Foundation
import QuartzCore
import Testing
@testable import Glimmer

struct TelemetryConfigRowTests {

    private func object(_ fields: [String]) throws -> [String: Any] {
        let data = Data(("{" + fields.joined(separator: ",") + "}").utf8)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func number(_ object: [String: Any], _ key: String) -> Double? {
        (object[key] as? NSNumber)?.doubleValue
    }

    @Test func configEventStatesTheStreamAndHowTheBitrateAskWasBuilt() throws {
        let decision = BitrateDecision(mode: .highestQuality, dialKbps: 100_000, codecMultiplier: 0.8,
                                       boost: 1.5, radioGatePhyMbps: 1_152)
        let stream = StreamTelemetryConfig(width: 3_840, height: 2_160, fps: 120, codec: "av1", bitrate: decision)
        let config = try object(TelemetryExporter.streamConfigFields(stream))
        #expect(number(config, "stream_width") == 3_840)
        #expect(number(config, "stream_height") == 2_160)
        #expect(number(config, "stream_fps") == 120)
        #expect(config["codec"] as? String == "av1")
        #expect(config["bitrate_mode"] as? String == BitrateMode.highestQuality.rawValue)
        #expect(number(config, "bitrate_dial_kbps") == 100_000)
        #expect(number(config, "bitrate_codec_mult") == 0.8)
        #expect(number(config, "bitrate_boost") == 1.5)
        #expect(number(config, "radio_gate_phy_mbps") == 1_152)

        var wired = stream
        wired.bitrate?.radioGatePhyMbps = nil
        #expect(try object(TelemetryExporter.streamConfigFields(wired))["radio_gate_phy_mbps"] == nil)
        #expect(TelemetryExporter.streamConfigFields(nil).isEmpty)
    }

    @Test func audioRateReadsZeroOnceTheFoldsStopButNotOnTheBeat() {
        // A tick between two ~1 s folds is the beat: no rate, as before.
        #expect(TelemetryExporter.audioPacketsPerSecond(delta: 0, sinceFold: 1.0) == nil)
        // No fold for two seconds is a blackout.
        #expect(TelemetryExporter.audioPacketsPerSecond(delta: 0, sinceFold: 2.0) == 0)
        #expect(TelemetryExporter.audioPacketsPerSecond(delta: 400, sinceFold: 2.0) == 200)
    }

    @Test func audioGapMaxCountsTheGapStillOpen() {
        let second: UInt64 = 1_000_000_000
        let gaps = AudioArrivalGaps()
        #expect(gaps.takeMaxMs(now: second) == nil)
        gaps.noteArrival(at: second, gapNanos: nil)
        gaps.noteArrival(at: second + 5_000_000, gapNanos: 5_000_000)
        #expect(gaps.takeMaxMs(now: second + 6_000_000) == 5)
        // Two seconds into a blackout the row already shows it.
        #expect(gaps.takeMaxMs(now: 3 * second + 5_000_000) == 2_000)
        // The first packet back closes a six-second gap.
        gaps.noteArrival(at: 7 * second + 5_000_000, gapNanos: 6 * second)
        #expect(gaps.takeMaxMs(now: 7 * second + 6_000_000) == 6_000)
    }

    /// A reconnect's new receiver has no gap of its own for its first datagram:
    /// the gap across the drop comes from the session's last datagram. A new
    /// session starts clean.
    @Test func audioGapMaxSpansAnInPlaceReconnect() {
        let second: UInt64 = 1_000_000_000
        let counters = TelemetryCounters()
        counters.anchorConnectStart(now: second, reconnecting: false)
        counters.audioArrivalGaps.noteArrival(at: second, gapNanos: nil)
        counters.anchorConnectStart(now: 2 * second, reconnecting: true)
        counters.audioArrivalGaps.noteArrival(at: 4 * second, gapNanos: nil)
        #expect(counters.audioArrivalGaps.takeMaxMs(now: 4 * second) == 3_000)
        counters.anchorConnectStart(now: 5 * second, reconnecting: false)
        #expect(counters.audioArrivalGaps.takeMaxMs(now: 5 * second) == nil)
    }

    @Test func rowAndReceiptCarryTheCushionCapDeadAirAndPadReportRate() throws {
        var snap = TelemetrySnapshot()
        var audio = AudioSnapshot()
        audio.packetsTotal = 1_000
        audio.packetsPerSecond = 0
        audio.gapMaxMs = 6_000
        snap.audio = audio
        var extras = TelemetrySnapshot.Extras()
        extras.audioCushionMaxMs = 200
        extras.audioUnderrunDeadairTotal = 3
        extras.dualSenseHidReportsPerSecond = 250
        let row = try #require(try JSONSerialization.jsonObject(
            with: Data(TelemetryRenderer.ndjson(snap, extras: extras).utf8)) as? [String: Any])
        #expect(number(row, "audio_pkts_per_s") == 0)
        #expect(number(row, "audio_gap_max_ms") == 6_000)
        #expect(number(row, "audio_cushion_max_ms") == 200)
        #expect(number(row, "audio_underrun_deadair_total") == 3)
        #expect(number(row, "dualsense_hid_reports_per_s") == 250)

        let counters = TelemetryCounters()
        counters.audioUnderrunDeadairTotal.increment(by: 2)
        let report = SessionReport(
            sessionId: "test", client: "mac", host: "pc", buildCommit: "c", buildDate: "d",
            generatedISO8601: "2026-09-22T00:00:00Z", durationSeconds: 60,
            aggregate: SessionAggregate(), histograms: nil, counters: counters)
        let receipt = try #require(try JSONSerialization.jsonObject(
            with: Data(report.renderJSON().utf8)) as? [String: Any])
        let events = try #require(receipt["events"] as? [String: Any])
        #expect(number(events, "audio_underrun_deadair") == 2)
    }

    @Test func worstGlassToGlassSecondUsesOnlyThatTicksObservations() {
        let histograms = LatencyHistograms()
        var aggregate = SessionAggregate()
        for _ in 0..<2_000 { histograms.glassToGlass.observe(10) }
        var snap = TelemetrySnapshot()
        snap.sinceConnectSeconds = 11
        snap.latencyHistograms = histograms.snapshot()
        aggregate.accumulate(snap, segment: .active)
        aggregate.foldLatency(histograms.snapshot(), active: true)

        for _ in 0..<100 { histograms.glassToGlass.observe(45) }
        snap.sinceConnectSeconds = 12
        snap.latencyHistograms = histograms.snapshot()
        aggregate.accumulate(snap, segment: .active)
        #expect((aggregate.worstGlassToGlassP95Ms ?? 0) > 40)
        #expect(aggregate.worstGlassToGlassP95AtSeconds == 12)
    }

    @Test func endToEndHistogramResolvesTheThirtyEightMillisecondTail() {
        let histograms = LatencyHistograms()
        for _ in 0..<1_000 { histograms.endToEnd.observe(38) }
        let p95 = TelemetryRenderer.histogramQuantile(0.95, stage: histograms.snapshot().endToEnd)
        #expect((p95 ?? .infinity) <= 40)
    }

    @Test func connectionResetKeepsSessionTotalsAndStartsAnEmptyWindow() {
        let stats = StatsCollector()
        for _ in 0..<3 { stats.recordPresentationLateDrop() }
        for frame in 0..<10 { stats.recordReceivedFrame(bytes: 1_000, frameNumber: Int32(frame)) }
        stats.recordDecoderDiscard()
        stats.recordRendererBackpressureDrop()
        stats.recordPresentationGap()

        stats.resetForConnection()
        #expect(stats.presentationLateDropCount() == 3)
        #expect(stats.presentationGapCount() == 1)
        #expect(stats.decoderDropCount() == 1)
        #expect(stats.backpressureDropCount() == 1)
        #expect(stats.receivedBytes == 10_000)
        stats.windowStart = CACurrentMediaTime() - 1
        let snap = stats.snapshot(minWindowSeconds: 0)
        #expect(snap.measuredBitrateMbps == 0)
        #expect(snap.receivedFps == 0)
        #expect(snap.decoderDroppedPercent == 10)
    }

    @Test func hostRateFallsBackToReceivedFramesWithoutTimingSupport() {
        var rate = StatsCollector.HostFrameRate(now: 0)
        for _ in 0..<120 { rate.record(hostProcessingLatency: 0) }
        let beforeWindow = rate.sample(now: 0.5)
        let complete = rate.sample(now: 1)
        #expect(beforeWindow == nil)
        #expect(complete == 120)
    }

    @Test func hostRateExcludesUntimedFramesOnceTimingIsAvailable() {
        var rate = StatsCollector.HostFrameRate(now: 0)
        for _ in 0..<60 {
            rate.record(hostProcessingLatency: 25)
            rate.record(hostProcessingLatency: 0)
        }
        let mixed = rate.sample(now: 1)
        for _ in 0..<120 { rate.record(hostProcessingLatency: 0) }
        let repeats = rate.sample(now: 2)
        #expect(mixed == 60)
        #expect(repeats == 0)
    }

    @Test func hostRateRollsAtOverlayCadenceWithoutShortWindowNoise() {
        var rate = StatsCollector.HostFrameRate(now: 0)
        for tick in 1...4 {
            for _ in 0..<60 { rate.record(hostProcessingLatency: 25) }
            let value = rate.sample(now: Double(tick) * 0.25)
            #expect(value == (tick == 4 ? 240 : nil))
        }
        for tick in 5...8 {
            for _ in 0..<8 { rate.record(hostProcessingLatency: 25) }
            let value = rate.sample(now: Double(tick) * 0.25)
            #expect(value == Double(240 - (tick - 4) * 52))
        }
        let cached = rate.sample(now: 2.1)
        #expect(cached == 32)
    }

    @Test func timingSupportReplacesFallbackAtNextOverlaySample() {
        var rate = StatsCollector.HostFrameRate(now: 0)
        for tick in 1...4 {
            for _ in 0..<30 { rate.record(hostProcessingLatency: 0) }
            _ = rate.sample(now: Double(tick) * 0.25)
        }
        for _ in 0..<8 { rate.record(hostProcessingLatency: 25) }
        let early = rate.sample(now: 1.1)
        let timed = rate.sample(now: 1.25)
        #expect(early == 120)
        #expect(timed == 8)
    }

    @Test func hostRateScalesByElapsedTimeAndFrequentReadersDoNotResetIt() {
        var rate = StatsCollector.HostFrameRate(now: 10)
        for _ in 0..<30 { rate.record(hostProcessingLatency: 25) }
        let early = rate.sample(now: 10.1)
        for _ in 0..<90 { rate.record(hostProcessingLatency: 25) }
        let complete = rate.sample(now: 12)
        let cached = rate.sample(now: 12.1)
        #expect(early == nil)
        #expect(complete == 60)
        #expect(cached == 60)
    }

    @Test func hostRateToleratesEarlyTimerTicksAndRetiresStaleSamples() {
        var rate = StatsCollector.HostFrameRate(now: 0)
        for tick in 1...8 {
            for _ in 0..<30 { rate.record(hostProcessingLatency: 25) }
            let value = rate.sample(now: Double(tick) * 0.249)
            if tick >= 4 { #expect(abs((value ?? 0) - 30 / 0.249) < 0.001) }
        }
        let idle = rate.sample(now: 4)
        #expect(idle == 0)
    }

    @Test func emptyHostRateWindowReportsZero() {
        var rate = StatsCollector.HostFrameRate(now: 0)
        let beforeWindow = rate.sample(now: 0.1)
        let empty = rate.sample(now: 1)
        #expect(beforeWindow == nil)
        #expect(empty == 0)
    }

    @Test func newHostRateStartsWithoutCachedValueOrTimingSupport() {
        var rate = StatsCollector.HostFrameRate(now: 0)
        rate.record(hostProcessingLatency: 25)
        let timed = rate.sample(now: 1)
        rate = StatsCollector.HostFrameRate(now: 2)
        let fresh = rate.sample(now: 2.5)
        for _ in 0..<120 { rate.record(hostProcessingLatency: 0) }
        let fallback = rate.sample(now: 3)
        #expect(timed == 1)
        #expect(fresh == nil)
        #expect(fallback == 120)
    }

    @Test func collectorReconnectClearsHostTimingSupport() {
        let stats = StatsCollector()
        stats.hostFrameRate = StatsCollector.HostFrameRate(now: 0)
        stats.recordReceivedFrame(bytes: 1_000, frameNumber: 0, hostProcessingLatency: 25)
        let timed = stats.hostFrameRate.sample(now: 1)
        stats.resetForConnection()
        let fresh = stats.hostFrameRate.sample(now: 0)
        for frame in 0..<120 { stats.recordReceivedFrame(bytes: 1_000, frameNumber: Int32(frame)) }
        let fallback = stats.hostFrameRate.sample(now: CACurrentMediaTime() + 2)
        #expect(timed == 1)
        #expect(fresh == nil)
        #expect((fallback ?? 0) > 0)
    }

    @Test func minimalRenderRowUsesCaptureEstimateAndPreservesPipelineRates() throws {
        var snap = StreamStatsSnapshot()
        snap.hostFps = 31.5
        snap.receivedFps = 120
        snap.renderedFps = 120
        let rows = snap.rows(enabled: StatsOverlayDefaults.minimalRows, targetFps: 120)
        let render = try #require(rows.first { $0.kind == .renderFps })
        #expect(rows.map(\.label) == ["Render", "Latency", "Bitrate"])
        #expect(render.value == "31.5 FPS")
        #expect(render.health == .neutral)
        #expect(snap.receivedFps == 120)
        #expect(snap.renderedFps == 120)
        let network = try #require(snap.rows(enabled: [.networkFps], targetFps: 120).first)
        #expect(network.value == "120.0 FPS")
        #expect(network.health == .neutral)
    }

    @Test func renderRowFallsBackToPresentationRateWithoutCaptureEstimate() throws {
        var snap = StreamStatsSnapshot()
        snap.renderedFps = 120
        let render = try #require(snap.rows(enabled: [.renderFps], targetFps: 120).first)
        #expect(render.label == "Render")
        #expect(render.value == "120.0 FPS")
        #expect(render.health == .neutral)
    }
    @Test @MainActor func fpsThresholdMigrationPreservesCustomValuesAndRunsOnce() throws {
        let name = "fps-threshold-tests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        var thresholds = StatsThresholds(fpsWarningBelow: 60, fpsCriticalBelow: 30, latencyWarningAbove: 75)
        defaults.set(try JSONEncoder().encode(thresholds), forKey: "statsThresholds")
        let migrated = AppModel.persistedStatsThresholds(defaults: defaults)
        #expect(migrated.fpsWarningBelow == 0)
        #expect(migrated.fpsCriticalBelow == 0)
        #expect(migrated.latencyWarningAbove == 75)
        defaults.set(try JSONEncoder().encode(thresholds), forKey: "statsThresholds")
        #expect(AppModel.persistedStatsThresholds(defaults: defaults) == thresholds)
        defaults.removeObject(forKey: "informationalFpsDefaultsApplied")
        thresholds.fpsWarningBelow = 45
        defaults.set(try JSONEncoder().encode(thresholds), forKey: "statsThresholds")
        #expect(AppModel.persistedStatsThresholds(defaults: defaults) == thresholds)
    }

    @Test func customFpsWarningsStillApplyToRenderEstimate() throws {
        var snap = StreamStatsSnapshot()
        let thresholds = StatsThresholds(fpsWarningBelow: 45, fpsCriticalBelow: 20)
        for (fps, health): (Double, StatsRow.Health) in [(32, .warning), (15, .critical), (60, .healthy)] {
            snap.hostFps = fps
            let row = try #require(snap.rows(enabled: [.renderFps], targetFps: 240, thresholds: thresholds).first)
            #expect(row.health == health)
        }
    }
}
