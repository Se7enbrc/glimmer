//
//  TelemetryFrameTrace.swift
//
//  The buffered, off-hot-path NDJSON writer for the per-frame latency trace.
//  Split out of TelemetryLatency.swift to keep each unit focused (the latency
//  histograms + the per-frame timing tracker stay there); see TelemetryExporter.
//  swift for the gate/safety contract.
//
//  HOT-PATH SAFETY (load-bearing): the hot path only appends a small pre-rendered
//  string to an in-memory buffer under a short lock; a ~250ms background timer
//  drains the buffer to disk in one write. NEVER fsyncs and never writes on the
//  producing thread — a slow disk can only grow the (bounded) buffer, never stall
//  decode/pace. The lock is taken ONLY on the telemetry path (off by default).
//

import Foundation
import os

// MARK: - Per-frame trace writer (batched, off the hot path)

/// Buffered background NDJSON writer for the per-frame latency trace. The hot
/// path only appends a small pre-rendered string to an in-memory buffer under a
/// short lock; a ~250ms background timer drains the buffer to disk in one write.
/// NEVER fsyncs and never writes on the producing thread — a slow disk can only
/// grow the (bounded) buffer, never stall decode/pace.
///
/// `@unchecked Sendable`: the buffer is lock-guarded; the file handle + timer are
/// confined to `flushQueue`.
final class FrameTraceWriter: @unchecked Sendable {

    private let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "Stream.Telemetry")

    /// Drain cadence. 250ms batches plenty of frames (15 at 60fps, 60 at 240fps)
    /// into one write while keeping the on-disk trace within a quarter-second of
    /// live for a tail.
    private static let flushInterval: DispatchTimeInterval = .milliseconds(250)

    /// Hard cap on the pending buffer so a wedged disk can't grow it without
    /// bound. At ~120 bytes/line this is ~1.2MB — far past one flush interval's
    /// worth of frames; overflow drops the OLDEST pending lines (diagnostic data,
    /// losing the stalest is the right tradeoff) and is logged once.
    private static let maxPendingLines = 10_000

    private let flushQueue = DispatchQueue(label: "io.ugfugl.Glimmer.telemetry.frames", qos: .utility)
    private var fileHandle: FileHandle?
    private var flushTimer: DispatchSourceTimer?

    /// Pending lines + their lock. The lock is taken ONLY on the telemetry path
    /// (which is off by default) — never on the proven decode/pace path when the
    /// gate is off, because the tracker that calls `append` doesn't exist then.
    private let bufferLock = os_unfair_lock_t.allocate(capacity: 1)
    private var pending: [String] = []
    private var droppedOverflow = false

    init() { bufferLock.initialize(to: os_unfair_lock_s()) }
    deinit { bufferLock.deallocate() }

    /// Open the trace file + arm the flush timer. Mirrors the exporter's NDJSON
    /// path: `~/Library/Logs/Glimmer/telemetry-frames-<ISO8601>.ndjson`.
    func start(isoStamp: String) {
        flushQueue.async { [weak self] in
            guard let self else { return }
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/Glimmer", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                self.log.error("Telemetry frames: could not create log dir: \(error.localizedDescription, privacy: .public)")
                return
            }
            let url = dir.appendingPathComponent("telemetry-frames-\(isoStamp).ndjson")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            do {
                self.fileHandle = try FileHandle(forWritingTo: url)
                self.log.notice("Telemetry per-frame trace → \(url.path, privacy: .public)")
            } catch {
                self.log.error("Telemetry frames: could not open file: \(error.localizedDescription, privacy: .public)")
                return
            }
            let timer = DispatchSource.makeTimerSource(queue: self.flushQueue)
            timer.schedule(deadline: .now() + Self.flushInterval, repeating: Self.flushInterval,
                           leeway: .milliseconds(50))
            timer.setEventHandler { [weak self] in self?.flush() }
            self.flushTimer = timer
            timer.resume()
        }
    }

    /// Stop the timer, flush whatever is pending, close the file. Synchronous so
    /// teardown is deterministic.
    func stop() {
        flushQueue.sync { [weak self] in
            guard let self else { return }
            self.flushTimer?.cancel()
            self.flushTimer = nil
            self.drainLocked()
            try? self.fileHandle?.close()
            self.fileHandle = nil
        }
    }

    /// Hot-path-side append: push one pre-rendered NDJSON line into the buffer
    /// under a short lock. No I/O here. Bounded — drops oldest on overflow.
    func append(_ line: String) {
        os_unfair_lock_lock(bufferLock)
        pending.append(line)
        if pending.count > Self.maxPendingLines {
            pending.removeFirst(pending.count - Self.maxPendingLines)
            droppedOverflow = true
        }
        os_unfair_lock_unlock(bufferLock)
    }

    /// Background drain: swap out the pending buffer under the lock, then write
    /// the batch in one go off the lock.
    private func flush() { drainLocked() }

    private func drainLocked() {
        os_unfair_lock_lock(bufferLock)
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        let overflowed = droppedOverflow
        droppedOverflow = false
        os_unfair_lock_unlock(bufferLock)

        if overflowed {
            log.error("Telemetry per-frame trace buffer overflowed (disk too slow?) — oldest lines dropped")
        }
        guard !batch.isEmpty, let fileHandle else { return }
        let blob = batch.joined(separator: "\n") + "\n"
        guard let data = blob.data(using: .utf8) else { return }
        do {
            try fileHandle.write(contentsOf: data)
        } catch {
            log.error("Telemetry per-frame trace write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
