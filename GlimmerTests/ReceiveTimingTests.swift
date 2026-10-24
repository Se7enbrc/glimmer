// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

@testable import GlimmerEngine
import Darwin
import Foundation
import Testing
@testable import Glimmer

struct ReceiveTimingTests {
    private func ticks(_ milliseconds: Double) -> UInt64 {
        UInt64((milliseconds / SocketTimestamp.millisecondsPerTick).rounded())
    }

    @Test func separatesArrivalFromReadAndThrottlesNotices() throws {
        let telemetry = ReceiveTimingTelemetry()
        var timing = ReceiveTiming(telemetry: telemetry)
        #expect(timing.observe(arrival: ticks(100), read: ticks(101)) == nil)
        let lateValue = timing.observe(arrival: ticks(110), read: ticks(325))
        let late = try #require(lateValue)
        #expect(late.kind == "late read")
        #expect(abs((late.queuedMs ?? 0) - 215) < 0.001)
        #expect(abs((late.arrivalMs ?? 0) - 10) < 0.001)
        #expect(timing.observe(arrival: ticks(600), read: ticks(601)) == nil)
        let arrivalValue = timing.observe(arrival: ticks(6_000), read: ticks(6_001))
        let arrival = try #require(arrivalValue)
        #expect(arrival.kind == "late arrival")
        let snapshot = telemetry.takeSnapshot()
        #expect(snapshot.samples == 4)
        #expect(abs((snapshot.delayMaxMs ?? 0) - 215) < 0.001)
        #expect(abs((snapshot.gapMaxMs ?? 0) - 5_400) < 0.001)
        #expect(telemetry.takeSnapshot().samples == 0)
        #expect(telemetry.takeSnapshot().delayP99Ms == nil)
    }

    @Test func missingFutureAndReorderedStampsNeverInventGaps() throws {
        let telemetry = ReceiveTimingTelemetry()
        var timing = ReceiveTiming(telemetry: telemetry)
        #expect(timing.observe(arrival: nil, read: ticks(100)) == nil)
        #expect(timing.observe(arrival: ticks(301), read: ticks(300))?.kind == "unavailable")
        #expect(timing.observe(arrival: ticks(400), read: ticks(401)) == nil)
        #expect(timing.observe(arrival: ticks(399), read: ticks(402)) == nil)
        let snapshot = telemetry.takeSnapshot()
        #expect(snapshot.missing == 2)
        #expect(snapshot.samples == 2)
        #expect(snapshot.gapMaxMs == nil)
    }

    @Test func percentilesAreWindowedAndKeepTheTail() {
        let telemetry = ReceiveTimingTelemetry()
        for _ in 0..<99 { telemetry.observe(delayMs: 0.3, gapMs: 5) }
        telemetry.observe(delayMs: 224, gapMs: 900)
        let snapshot = telemetry.takeSnapshot()
        #expect(snapshot.delayP99Ms == 0.5)
        #expect(snapshot.delayMaxMs == 224)
        #expect(snapshot.gapP99Ms == 5)
        #expect(snapshot.gapMaxMs == 900)
        telemetry.observe(delayMs: 1, gapMs: nil)
        #expect(telemetry.takeSnapshot().delayMaxMs == 1)
        telemetry.observe(delayMs: 2, gapMs: 4)
        telemetry.reset()
        #expect(telemetry.takeSnapshot().samples == 0)
    }

    @Test func ancillaryParserRejectsTruncatedAndMalformedRecords() {
        let storage = UnsafeMutableRawPointer.allocate(byteCount: SocketTimestamp.controlSize, alignment: 8)
        defer { storage.deallocate() }
        storage.initializeMemory(as: UInt8.self, repeating: 0, count: SocketTimestamp.controlSize)
        let headerSize = MemoryLayout<cmsghdr>.size
        var header = cmsghdr(cmsg_len: socklen_t(headerSize + 8), cmsg_level: SOL_SOCKET,
                             cmsg_type: SCM_TIMESTAMP_MONOTONIC)
        storage.storeBytes(of: header, as: cmsghdr.self)
        storage.storeBytes(of: UInt64(1234), toByteOffset: headerSize, as: UInt64.self)
        #expect(SocketTimestamp.arrival(in: storage, length: headerSize + 8, flags: 0) == 1234)
        #expect(SocketTimestamp.arrival(in: storage, length: headerSize + 8, flags: MSG_CTRUNC) == nil)
        #expect(SocketTimestamp.arrival(in: storage, length: headerSize + 7, flags: 0) == nil)
        header.cmsg_len = 0
        storage.storeBytes(of: header, as: cmsghdr.self)
        #expect(SocketTimestamp.arrival(in: storage, length: headerSize + 8, flags: 0) == nil)
        #expect(SocketTimestamp.arrival(in: nil, length: 0, flags: 0) == nil)
        #expect(!SocketTimestamp.enable(on: -1))
    }
    @Test func bothRenderersExportEachSocketAndOmitEmptyWindowMeasurements() throws {
        var snapshot = TelemetryRenderFixtures.snapshot()
        snapshot.receiveVideo = .init(samples: 100, missing: 2, delayMaxMs: 224, delayP99Ms: 2,
                                      gapMaxMs: 8, gapP99Ms: 5)
        snapshot.receiveAudio = .init(samples: 200, delayMaxMs: 225, delayP99Ms: 3, gapMaxMs: 9, gapP99Ms: 6)
        let extras = TelemetrySnapshot.Extras()
        let row = try TelemetryRenderFixtures.row(TelemetryRenderer.ndjson(snapshot, extras: extras))
        let prom = TelemetryRenderer.prometheus(snapshot, extras: extras)
        for (name, value) in [("video", 224), ("audio", 225)] {
            #expect((row["\(name)_rx_read_delay_max_ms"] as? NSNumber)?.intValue == value)
            #expect(prom.contains("glimmer_\(name)_rx_read_delay_max_ms"))
            #expect(row["\(name)_rx_kernel_gap_p99_ms"] != nil)
        }
        #expect(!row.keys.contains { $0.hasPrefix("enet_rx_") })
        #expect(!prom.contains("glimmer_enet_rx_"))
        #expect((row["video_rx_timestamp_missing"] as? NSNumber)?.intValue == 2)
        snapshot.receiveVideo = .init()
        let empty = try TelemetryRenderFixtures.row(TelemetryRenderer.ndjson(snapshot, extras: extras))
        #expect(empty["video_rx_read_delay_max_ms"] == nil)
        #expect((empty["video_rx_timestamp_samples"] as? NSNumber)?.intValue == 0)
    }
    @Test(arguments: [0.0, 0.1, 4, 4.1, 20, 20.1, 100, 100.1, 500, 900])
    func histogramBoundariesPreserveAnExactSingleSample(milliseconds: Double) {
        var distribution = ReceiveTimingTelemetry.Distribution()
        distribution.observe(milliseconds)
        #expect(distribution.p99 == milliseconds)
        #expect(distribution.maximum == milliseconds)
    }
    @Test func oneBatchKeepsIndividualKernelGapsAndOneReadTime() {
        let telemetry = ReceiveTimingTelemetry()
        var timing = ReceiveTiming(telemetry: telemetry)
        #expect(timing.observe(arrival: ticks(100), read: ticks(325)) == nil)
        #expect(timing.observe(arrival: ticks(110), read: ticks(325)) == nil)
        #expect(timing.observe(arrival: ticks(330), read: ticks(331)) == nil)
        let snapshot = telemetry.takeSnapshot()
        #expect(snapshot.samples == 3)
        #expect(abs((snapshot.delayMaxMs ?? 0) - 225) < 0.001)
        #expect(abs((snapshot.gapMaxMs ?? 0) - 220) < 0.001)
    }

    @Test func mixedPausesRetainBothPiecesOfEvidence() throws {
        var timing = ReceiveTiming(telemetry: ReceiveTimingTelemetry())
        #expect(timing.observe(arrival: ticks(100), read: ticks(101)) == nil)
        let result = timing.observe(arrival: ticks(325), read: ticks(550))
        let gap = try #require(result)
        #expect(gap.kind == "late read")
        #expect(abs((gap.queuedMs ?? 0) - 225) < 0.001)
        #expect(abs((gap.arrivalMs ?? 0) - 225) < 0.001)
    }

    @Test(arguments: [102.0, 600.0])
    func separatesReceiveCallFromWorkBetweenCalls(startMs: Double) throws {
        var timing = ReceiveTiming(telemetry: ReceiveTimingTelemetry())
        #expect(timing.observe(arrival: ticks(100), read: ticks(101)) == nil)
        let result = timing.observe(arrival: ticks(105), read: ticks(602),
                                    callStarted: ticks(startMs), previousCallFinished: ticks(101))
        let gap = try #require(result)
        #expect(abs((gap.receiveCallMs ?? 0) - (602 - startMs)) < 0.001)
        #expect(abs((gap.betweenCallsMs ?? 0) - (startMs - 101)) < 0.001)
        #expect(abs((gap.queuedMs ?? 0) - 497) < 0.001)
        #expect(gap.kind == "late read")
    }

    @Test func timeoutBetweenPacketsDoesNotBecomeProcessingTime() throws {
        var timing = ReceiveTiming(telemetry: ReceiveTimingTelemetry())
        #expect(timing.observe(arrival: ticks(100), read: ticks(101)) == nil)
        let result = timing.observe(arrival: ticks(600), read: ticks(602),
                                    callStarted: ticks(502), previousCallFinished: ticks(501))
        let gap = try #require(result)
        #expect(abs(gap.readMs - 501) < 0.001)
        #expect(abs((gap.receiveCallMs ?? 0) - 100) < 0.001)
        #expect(abs((gap.betweenCallsMs ?? 0) - 1) < 0.001)
        #expect(gap.kind == "late arrival")
    }

    @Test func invalidCallClocksStayUnavailable() throws {
        var timing = ReceiveTiming(telemetry: ReceiveTimingTelemetry())
        #expect(timing.observe(arrival: nil, read: ticks(100)) == nil)
        let result = timing.observe(arrival: nil, read: ticks(300),
                                    callStarted: ticks(301), previousCallFinished: ticks(302))
        let gap = try #require(result)
        #expect(gap.receiveCallMs == nil)
        #expect(gap.betweenCallsMs == nil)
        let fields = gap.fields(stream: "video", read: ticks(300), threadID: 42, queuedCount: nil)
        let row = try TelemetryRenderFixtures.row("{" + fields.joined(separator: ",") + "}")
        #expect(row["receive_call_ms"] is NSNull)
        #expect(row["between_calls_ms"] is NSNull)
        #expect(row["kernel_gap_ms"] is NSNull)
        #expect(row["queued_count"] is NSNull)
        #expect(row["event"] as? String == "receive_gap")
        #expect(row["thread_id"] as? Int == 42)
        #expect(abs((row["t_ms"] as? Double ?? 0) - 300) < 0.001)
    }

    @Test func throttledIncidentsRemainCountedInTheNextReport() throws {
        var timing = ReceiveTiming(telemetry: ReceiveTimingTelemetry())
        #expect(timing.observe(arrival: nil, read: ticks(100)) == nil)
        #expect(timing.observe(arrival: nil, read: ticks(200))?.reportsSuppressed == 0)
        #expect(timing.observe(arrival: nil, read: ticks(300)) == nil)
        #expect(timing.observe(arrival: nil, read: ticks(400)) == nil)
        let nextValue = timing.observe(arrival: nil, read: ticks(5_200))
        let next = try #require(nextValue)
        #expect(next.reportsSuppressed == 2)
        #expect(timing.observe(arrival: nil, read: ticks(10_200))?.reportsSuppressed == 0)
    }

    @Test func thresholdCrossedByCombinedDelaysDoesNotBlameTheReader() throws {
        var timing = ReceiveTiming(telemetry: ReceiveTimingTelemetry())
        #expect(timing.observe(arrival: ticks(100), read: ticks(101)) == nil)
        let value = timing.observe(arrival: ticks(149.5), read: ticks(152))
        let gap = try #require(value)
        #expect(gap.kind == "split delay")
        #expect(abs((gap.queuedMs ?? 0) - 2.5) < 0.001)
        #expect(abs((gap.arrivalMs ?? 0) - 49.5) < 0.001)
    }
}
