// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Darwin
import Foundation

// Each receive loop owns its cursor; only the per-second histogram crosses threads.
struct ReceiveTiming {
    struct Gap: Equatable {
        var kind: String
        var readMs: Double
        var arrivalMs: Double?
        var queuedMs: Double?
    }

    let telemetry: ReceiveTimingTelemetry
    private var previousRead: UInt64?
    private var previousArrival: UInt64?
    private var lastNotice: UInt64?

    mutating func observe(arrival: UInt64?, read: UInt64) -> Gap? {
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
        guard let readGap, readGap > 50,
              lastNotice.map({ Double(read - $0) * scale >= 5_000 }) ?? true else { return nil }
        lastNotice = read
        let kind: String
        if let delay, delay > 50 {
            kind = "late read"
        } else if let gap, gap > 50 {
            kind = "late arrival"
        } else if delay != nil, gap != nil {
            kind = "late read"
        } else {
            kind = "unavailable"
        }
        return Gap(kind: kind, readMs: readGap, arrivalMs: gap, queuedMs: delay)
    }

    mutating func note(_ batch: DatagramBatch, index: Int, count: Int, socket: Int32, stream: String) {
        guard let gap = observe(arrival: batch.arrivalTicks(at: index), read: batch.readTicks) else { return }
        var queued: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        let queueKnown = getsockopt(socket, SOL_SOCKET, SO_NUMRCVPKT, &queued, &size) == 0
        var threadID: UInt64 = 0
        pthread_threadid_np(nil, &threadID)
        let qos = qos_class_self().rawValue
        let reader = "Glimmer.\(stream)Recv"
        Diag.notice("Receive gap stream=\(stream) kind=\(gap.kind) read_ms=\(gap.readMs) "
            + "kernel_gap_ms=\(gap.arrivalMs ?? -1) queued_ms=\(gap.queuedMs ?? -1) "
            + "queued_count=\(queueKnown ? Int(queued) + count - index : -1) "
            + "reader=\(reader) tid=\(threadID) qos=\(qos)", "Stream.Receive")
    }
}
