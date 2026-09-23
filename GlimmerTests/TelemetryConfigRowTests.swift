//
//  TelemetryConfigRowTests.swift
//
//  What a session's config event says about the stream and its bitrate ask, and
//  how the 1 Hz audio fields tell a blackout from the fold beat.
//

import Foundation
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
}
