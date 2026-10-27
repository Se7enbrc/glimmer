// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

#if os(macOS)
import Darwin
import Foundation
import os

// Each receive loop owns its clocks; shared histograms and throttled events carry observations off-thread.
struct ReceiveTiming {
    struct Gap: Equatable {
        var kind: String
        var readMs: Double
        var arrivalMs: Double?
        var queuedMs: Double?
        var receiveCallMs: Double?
        var betweenCallsMs: Double?
        var reportsSuppressed: UInt64 = 0

        func fields(stream: String, read: UInt64, threadID: UInt64, queuedCount: Int?) -> [String] {
            func number(_ value: Double?) -> String {
                value.map(TelemetryRenderer.jsonNumber) ?? "null"
            }
            return [
                "\"event\":\"receive_gap\"", "\"stream\":\"\(stream)\"", "\"kind\":\"\(kind)\"",
                "\"t_ms\":\(number(Double(read) * SocketTimestamp.millisecondsPerTick))",
                "\"thread_id\":\(threadID)", "\"read_gap_ms\":\(number(readMs))",
                "\"kernel_gap_ms\":\(number(arrivalMs))", "\"queued_ms\":\(number(queuedMs))",
                "\"receive_call_ms\":\(number(receiveCallMs))",
                "\"between_calls_ms\":\(number(betweenCallsMs))",
                "\"queued_count\":\(queuedCount.map(String.init) ?? "null")",
                "\"reports_suppressed\":\(reportsSuppressed)"
            ]
        }
    }

    let telemetry: ReceiveTimingTelemetry
    private var previousRead: UInt64?
    private var previousArrival: UInt64?
    private var lastNotice: UInt64?
    private var suppressedNotices: UInt64 = 0

    init(telemetry: ReceiveTimingTelemetry) {
        self.telemetry = telemetry
    }

    mutating func observe(arrival: UInt64?, read: UInt64,
                          callStarted: UInt64? = nil, previousCallFinished: UInt64? = nil) -> Gap? {
        let scale = SocketTimestamp.millisecondsPerTick
        let valid = arrival.flatMap { $0 <= read ? $0 : nil }
        let delay = valid.map { Double(read - $0) * scale }
        let gap = valid.flatMap { current in
            previousArrival.flatMap { current >= $0 ? Double(current - $0) * scale : nil }
        }
        let readGap = previousRead.flatMap { read >= $0 ? Double(read - $0) * scale : nil }
        previousRead = read
        previousArrival = valid
        telemetry.observe(delayMs: delay, gapMs: gap)
        guard let readGap, readGap > 50 else { return nil }
        guard lastNotice.map({ read >= $0 && Double(read - $0) * scale >= 5_000 }) ?? true else {
            suppressedNotices &+= 1
            return nil
        }
        lastNotice = read
        let kind: String
        if let delay, delay > 50 {
            kind = "late read"
        } else if let gap, gap > 50 {
            kind = "late arrival"
        } else if delay != nil, gap != nil {
            kind = "split delay"
        } else {
            kind = "unavailable"
        }
        let validStart = callStarted.flatMap { $0 > 0 && $0 <= read ? $0 : nil }
        let callMs = validStart.map { Double(read - $0) * scale }
        let betweenMs = validStart.flatMap { start in
            previousCallFinished.flatMap { end in
                end > 0 && end <= start ? Double(start - end) * scale : nil
            }
        }
        defer { suppressedNotices = 0 }
        return Gap(kind: kind, readMs: readGap, arrivalMs: gap, queuedMs: delay,
                   receiveCallMs: callMs, betweenCallsMs: betweenMs, reportsSuppressed: suppressedNotices)
    }

    mutating func note(_ batch: DatagramBatch, index: Int, count: Int, socket: Int32, stream: String) {
        guard let gap = observe(arrival: batch.arrivalTicks(at: index), read: batch.readTicks,
                              callStarted: batch.readStartedTicks,
                              previousCallFinished: batch.previousReadTicks) else { return }
        var queued: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        let queueKnown = getsockopt(socket, SOL_SOCKET, SO_NUMRCVPKT, &queued, &size) == 0
        var threadID: UInt64 = 0
        pthread_threadid_np(nil, &threadID)
        let qos = qos_class_self().rawValue
        let reader = "Glimmer.\(stream)Recv"
        let queuedCount = queueKnown ? Int(queued) + count - index : nil
        Diag.notice("Receive gap stream=\(stream) kind=\(gap.kind) read_ms=\(gap.readMs) "
            + "kernel_gap_ms=\(gap.arrivalMs ?? -1) queued_ms=\(gap.queuedMs ?? -1) "
            + "queued_count=\(queuedCount ?? -1) receive_call_ms=\(gap.receiveCallMs ?? -1) "
            + "between_calls_ms=\(gap.betweenCallsMs ?? -1) reports_suppressed=\(gap.reportsSuppressed) "
            + "t_ms=\(Double(batch.readTicks) * SocketTimestamp.millisecondsPerTick) "
            + "reader=\(reader) tid=\(threadID) qos=\(qos)", "Stream.Receive")
        TelemetryExporter.recordLiveEvent(gap.fields(stream: stream, read: batch.readTicks,
                                                    threadID: threadID, queuedCount: queuedCount))
        OSSignposter.network.emitEvent("ReceiveGap",
            """
            stream=\(stream, privacy: .public) tid=\(threadID) read_ms=\(gap.readMs) \
            call_ms=\(gap.receiveCallMs ?? -1) between_ms=\(gap.betweenCallsMs ?? -1)
            """)
    }
}

#else
struct ReceiveTiming {
    enum Source { case video, audio }
    private let source: Source
    init(telemetry: Source) { source = telemetry }
    @inline(__always)
    mutating func note(_ batch: DatagramBatch, index: Int, count: Int,
                       socket: Int32, stream: String) {
        #if GLIMMER_DIAGNOSTICS
        guard source == .video, let arrival = batch.arrivalTicks(at: index), arrival <= batch.readTicks else { return }
        let delay = Double(batch.readTicks - arrival) * SocketTimestamp.millisecondsPerTick
        ReceivePolicyMeasurements.video.observeDelay(delay)
        #endif
    }
}
#endif
