//
//  VideoRecoveryEventTests.swift
//
//  The video receive path's recovery rows: one loss episode per RFI recovery,
//  a key-frame row that says whether it was asked for, and a row per long gap.
//

import Foundation
import Testing
@testable import Glimmer

struct VideoRecoveryEventTests {

    private func object(_ fields: [String]) throws -> [String: Any] {
        let data = Data(("{" + fields.joined(separator: ",") + "}").utf8)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func number(_ object: [String: Any], _ key: String) -> Double? {
        (object[key] as? NSNumber)?.doubleValue
    }

    @Test func oneEpisodeSpansEveryLossReportUntilTheRecoveryFrame() throws {
        var episode = VideoLossEpisode()
        let start: UInt64 = 5_000_000_000
        let opened = episode.noteLoss(from: 423_451, to: 423_452, nowNanos: start, rfisSent: 10)
        #expect(opened)
        // The depacketizer re-reports the growing window for every frame it drops.
        var reopenings = 0
        for frame in 423_453...423_484
        where episode.noteLoss(from: 423_451, to: frame, nowNanos: start + 1_000_000, rfisSent: 12) {
            reopenings += 1
        }
        #expect(reopenings == 0)
        let closed = episode.close(frame: 423_485, isIDR: false, nowNanos: start + 145_000_000, rfisSent: 15)
        let summary = try #require(closed)
        #expect(summary.discardedCount == 34)
        #expect(summary.lastDiscarded == 423_484)
        #expect(summary.rfisSent == 5)
        #expect(summary.recoveryMs == 145)
        #expect(!episode.isOpen)
        let closedAgain = episode.close(frame: 423_486, isIDR: false, nowNanos: start, rfisSent: 15)
        #expect(closedAgain == nil)

        let row = try object(summary.eventFields(atNanos: start + 145_000_000))
        #expect(row["event"] as? String == "loss_episode")
        #expect(row["recovered_by"] as? String == "rfi")
        #expect(number(row, "first_frame") == 423_451)
        #expect(number(row, "discarded_count") == 34)
        #expect(number(row, "rfis_sent") == 5)
        #expect(number(row, "recovery_ms") == 145)
    }

    @Test func anEpisodeCountsAcrossTheFrameIndexWrap() throws {
        var episode = VideoLossEpisode()
        _ = episode.noteLoss(from: Int(UInt32.max) - 1, to: Int(UInt32.max), nowNanos: 0, rfisSent: 0)
        let closed = episode.close(frame: 2, isIDR: true, nowNanos: 1_000_000, rfisSent: 1)
        let summary = try #require(closed)
        #expect(summary.discardedCount == 4)
        #expect(summary.byIDR)
    }

    @Test func keyFrameRowSaysWhetherItWasAskedFor() throws {
        let rekey = try object(VideoRtpReceiver.idrReceivedFields(
            frame: 18_022, atNanos: 7, requested: false, roundTripMs: nil, bytes: 37_000))
        #expect(rekey["event"] as? String == "idr_received")
        #expect(rekey["requested"] as? Bool == false)
        #expect(rekey["round_trip_ms"] == nil)
        let answered = try object(VideoRtpReceiver.idrReceivedFields(
            frame: 18_022, atNanos: 7, requested: true, roundTripMs: 14, bytes: 37_000))
        #expect(answered["requested"] as? Bool == true)
        #expect(number(answered, "round_trip_ms") == 14)
    }

    @Test func onlyAGapPastOneHundredMillisecondsGetsARow() throws {
        #expect(RtpVideoQueue.gapEventFields(gapUs: 99_000, atUs: 1_000_000, lastSeq: 1, nextSeq: 2) == nil)
        let fields = try #require(RtpVideoQueue.gapEventFields(
            gapUs: 358_000, atUs: 1_000_000, lastSeq: 65_535, nextSeq: 3))
        let row = try object(fields)
        #expect(row["event"] as? String == "video_gap")
        #expect(number(row, "gap_ms") == 358)
        #expect(number(row, "t_ns") == 1_000_000_000)
        #expect(number(row, "last_seq") == 65_535)
        #expect(number(row, "next_seq") == 3)
    }
}
