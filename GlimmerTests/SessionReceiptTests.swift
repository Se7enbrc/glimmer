//
//  SessionReceiptTests.swift
//
//  The session receipt across an in-place reconnect: one session's totals, the
//  first connect's handshake with the reconnect's alongside, and audio that
//  never arrived stated as such.
//

import Foundation
import Testing
@testable import Glimmer

struct SessionReceiptTests {

    private static let msNanos: UInt64 = 1_000_000

    private func receipt(_ counters: TelemetryCounters) throws -> [String: Any] {
        let report = SessionReport(
            sessionId: "test", client: "mac", host: "pc", buildCommit: "c", buildDate: "d",
            generatedISO8601: "2026-09-22T00:00:00Z", durationSeconds: 60,
            aggregate: SessionAggregate(), histograms: nil, counters: counters)
        let data = Data(report.renderJSON().utf8)
        return try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    private func number(_ object: Any?, _ key: String) -> Double? {
        ((object as? [String: Any])?[key] as? NSNumber)?.doubleValue
    }

    /// A first connect whose RTSP leg took `rtspMs`, starting `agoMs` in the past.
    private func connect(_ counters: TelemetryCounters, agoMs: UInt64, rtspMs: UInt64) {
        let start = TelemetryCounters.monotonicNowNanos() - agoMs * Self.msNanos
        counters.p2.markRtspStart(start)
        counters.p2.markRtspDone(start + rtspMs * Self.msNanos)
        counters.p2.markEnetStart(start + (rtspMs + 1) * Self.msNanos)
        counters.p2.markEstablished()
    }

    @Test func aReconnectKeepsTheSessionTotalsAndTheFirstHandshake() throws {
        let counters = TelemetryCounters()
        counters.anchorConnectStart(now: TelemetryCounters.monotonicNowNanos() - 5_000 * Self.msNanos,
                                    reconnecting: false)
        connect(counters, agoMs: 5_000, rtspMs: 200)
        counters.decodeGatedDropTotal.increment(by: 165)
        counters.rfiTotal.increment(by: 4)

        // The drop, then the in-place reconnect's own connect.
        counters.anchorConnectStart(now: TelemetryCounters.monotonicNowNanos(), reconnecting: true)
        connect(counters, agoMs: 1_000, rtspMs: 150)
        counters.reconnectTotal.increment()

        let json = try receipt(counters)
        let events = json["events"] as? [String: Any]
        #expect(number(events, "drops_decode_gated") == 165)
        #expect(number(events, "rfi") == 4)
        #expect(number(json["lifecycle"], "reconnects") == 1)

        let handshake = try #require(json["handshake"] as? [String: Any])
        #expect(number(handshake, "rtsp_ms") == 200)
        #expect(number(handshake, "control_setup_ms") == 1)
        #expect(handshake["pairing_ms"] == nil)
        let last = try #require(handshake["reconnect_last"] as? [String: Any])
        #expect(number(last, "rtsp_ms") == 150)
        #expect(last["click_to_first_frame_ms"] == nil)
    }

    @Test func aNewSessionStartsItsReconnectAndWakeCountsAtZero() {
        let counters = TelemetryCounters()
        counters.reconnectTotal.increment(by: 2)
        counters.wakeTotal.increment()
        let now = TelemetryCounters.monotonicNowNanos()
        counters.anchorConnectStart(now: now, reconnecting: true)
        #expect(counters.reconnectTotal.value == 2)
        counters.anchorConnectStart(now: now, reconnecting: false)
        #expect(counters.reconnectTotal.value == 0)
        #expect(counters.wakeTotal.value == 0)
    }

    /// The reorder-hold totals are session totals like the rest: a reconnect keeps
    /// them, and only a new session starts them at zero.
    @Test func reorderHoldTotalsCountTheWholeSession() {
        let counters = TelemetryCounters()
        let now = TelemetryCounters.monotonicNowNanos()
        counters.anchorConnectStart(now: now, reconnecting: false)
        counters.reorderHoldTakenTotal.increment(by: 5)
        counters.reorderHoldRescuedTotal.increment(by: 3)
        counters.anchorConnectStart(now: now, reconnecting: true)
        #expect(counters.reorderHoldTakenTotal.value == 5)
        #expect(counters.reorderHoldRescuedTotal.value == 3)
        counters.anchorConnectStart(now: now, reconnecting: false)
        #expect(counters.reorderHoldTakenTotal.value == 0)
        #expect(counters.reorderHoldRescuedTotal.value == 0)
    }

    @Test func audioTimeToFirstPacketComesFromTheFirstConnect() throws {
        let counters = TelemetryCounters()
        counters.anchorConnectStart(now: TelemetryCounters.monotonicNowNanos() - 3_000 * Self.msNanos,
                                    reconnecting: false)
        counters.recordAudioFirstPacket()
        counters.audioPacketsTotal.increment(by: 200)
        let firstTtf = try #require(counters.audioFirstPacketMs)

        counters.anchorConnectStart(now: TelemetryCounters.monotonicNowNanos() - 500 * Self.msNanos,
                                    reconnecting: true)
        counters.recordAudioFirstPacket()

        let ttf = try #require(try receipt(counters)["audio_ttf"] as? [String: Any])
        let reported = try #require(number(ttf, "ttf_ms"))
        #expect(abs(reported - firstTtf) < 0.01)
        #expect(ttf["never"] == nil)
    }

    @Test func aSessionThatNeverHeardAudioSaysSo() throws {
        let counters = TelemetryCounters()
        counters.resetForNewSession()
        let ttf = try #require(try receipt(counters)["audio_ttf"] as? [String: Any])
        #expect(ttf["never"] as? Bool == true)
        #expect(number(ttf, "pings") != nil)

        counters.audioPacketsTotal.increment(by: 3)
        let heard = try #require(try receipt(counters)["audio_ttf"] as? [String: Any])
        #expect(heard["never"] == nil)
    }
}
