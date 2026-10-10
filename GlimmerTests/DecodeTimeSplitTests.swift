//
//  DecodeTimeSplitTests.swift
//
//  How a frame's submit-to-callback time splits into VT service and queue wait,
//  how the Decode time row shows it, and how the config event names the decode mode.
//

import Foundation
import Testing
import os
@testable import Glimmer

struct DecodeTimeSplitTests {

    private func expectSplit(_ submit: Double, _ callback: Double, after previous: Double,
                             service: Double, wait: Double) {
        let split = StatsCollector.decodeTimeSplit(
            submit: submit, callback: callback, previousCallback: previous)
        #expect(abs(split.service - service) < 1e-9)
        #expect(abs(split.wait - wait) < 1e-9)
    }

    @Test func pipelinedFrameWaitsForThePreviousCallback() {
        // Submitted at 10, the previous frame finished at 12: 2 waiting, 1.5 decoding.
        expectSplit(10, 13.5, after: 12, service: 1.5, wait: 2)
    }

    @Test func frameAfterAnIdleGapIsAllService() {
        expectSplit(10, 12.4, after: 5, service: 2.4, wait: 0)
        // First frame of a connection: no previous callback yet.
        expectSplit(10, 12.4, after: 0, service: 2.4, wait: 0)
    }

    @Test func outOfOrderAnchorsNeverGoNegative() {
        // A previous callback stamped after this one counts as all wait, never more.
        expectSplit(10, 12, after: 15, service: 0, wait: 2)
        // A callback stamped before its submit is an empty span.
        expectSplit(10, 9, after: 11, service: 0, wait: 0)
    }

    @Test func collectorKeepsTheSplitAlongsideTheTotalAndResetsIt() throws {
        let stats = StatsCollector()
        for _ in 0..<3 {
            stats.recordDecodeSubmit(intervalState: OSSignposter.decode.beginInterval("DecodeFrame"))
        }
        for _ in 0..<3 { _ = stats.recordDecodeComplete(dropped: false) }
        let snap = stats.snapshot()
        let total = try #require(snap.avgDecodeTimeMs)
        let service = try #require(snap.avgDecodeServiceMs)
        let wait = try #require(snap.avgDecodeWaitMs)
        #expect(service >= 0 && wait >= 0)
        #expect(abs(service + wait - total) < 1e-6)

        stats.resetForConnection()
        let reset = stats.snapshot()
        #expect(reset.avgDecodeServiceMs == nil && reset.avgDecodeWaitMs == nil)
    }

    @Test func decodeTimeRowShowsTheSplitOnlyWhenFramesWait() throws {
        var snap = StreamStatsSnapshot()
        snap.avgDecodeTimeMs = 2.76
        snap.avgDecodeServiceMs = 2.41
        snap.avgDecodeWaitMs = 0.35
        let split = try #require(snap.rows(enabled: [.decodeTime], targetFps: 240).first)
        #expect(split.value == "2.76 ms \u{00B7} 2.41 + 0.35 wait")

        snap.avgDecodeServiceMs = 2.72
        snap.avgDecodeWaitMs = 0.04
        let total = try #require(snap.rows(enabled: [.decodeTime], targetFps: 240).first)
        #expect(total.value == "2.76 ms")
    }

    @Test func telemetryExportsTheSplitNextToTheTotal() {
        var snap = TelemetrySnapshot()
        snap.decodeEmaMs = 2.76
        snap.decodeServiceMs = 2.41
        snap.decodeWaitMs = 0.35
        let extras = TelemetrySnapshot.Extras()
        let json = TelemetryRenderer.ndjson(snap, extras: extras)
        #expect(json.contains("\"decode_service_ms\":2.41") && json.contains("\"decode_wait_ms\":0.35"))
        let prom = TelemetryRenderer.prometheus(snap, extras: extras)
        #expect(prom.contains("glimmer_decode_service_ema_ms") && prom.contains("glimmer_decode_wait_ema_ms"))
    }

    @Test func configEventNamesTheDecodeMode() {
        var stream = StreamTelemetryConfig(width: 1_920, height: 1_080, fps: 240, codec: "av1", bitrate: nil)
        #expect(TelemetryExporter.streamConfigFields(stream).contains("\"decode_synchronous\":false"))
        stream.decodeSynchronous = true
        #expect(TelemetryExporter.streamConfigFields(stream).contains("\"decode_synchronous\":true"))
    }
}
