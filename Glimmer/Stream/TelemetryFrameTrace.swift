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
//  producing thread - a slow disk can only grow the (bounded) buffer, never stall
//  decode/pace. The lock is taken ONLY on the telemetry path (off by default).
//

import Foundation
import os

// MARK: - Per-frame trace writer (batched, off the hot path)

/// Buffered background NDJSON writer for the per-frame latency trace. The hot
/// path only appends a small pre-rendered string to an in-memory buffer under a
/// short lock; a ~250ms background timer drains the buffer to disk in one write.
/// NEVER fsyncs and never writes on the producing thread - a slow disk can only
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
    /// bound. At ~120 bytes/line this is ~1.2MB - far past one flush interval's
    /// worth of frames; overflow drops the OLDEST pending lines (diagnostic data,
    /// losing the stalest is the right tradeoff) and is logged once.
    private static let maxPendingLines = 10_000

    /// SIZE-CAPPED ROLLOVER (C2): the per-frame trace writes ~275B/presented
    /// frame unconditionally - ~1.5GB/6h unbounded. Past this many bytes the
    /// current file is closed and a fresh `-<n>` segment opens; only the last
    /// `maxTraceFiles` segments of THIS session are kept (older ones pruned). The
    /// steady-state signal still lives in the 1Hz NDJSON sink, so a bounded tail
    /// of the per-frame detail is the right tradeoff. 96MB × 4 ≈ 384MB ceiling.
    private static let maxFileBytes: UInt64 = 96 * 1024 * 1024
    private static let maxTraceFiles = 4

    private let flushQueue = DispatchQueue(label: "io.ugfugl.Glimmer.telemetry.frames", qos: .utility)
    private var fileHandle: FileHandle?
    private var flushTimer: DispatchSourceTimer?
    /// Rollover state (flushQueue-confined): the Logs dir + this session's ISO
    /// stamp (so segments share a prefix), the running byte count of the current
    /// segment, the next segment index, and the segment files written this session
    /// (oldest-first, for the keep-last-K prune).
    private var logDir: URL?
    private var isoStamp = ""
    private var bytesWritten: UInt64 = 0
    private var rolloverIndex = 0
    private var segmentURLs: [URL] = []

    /// Pending lines + their lock. The lock is taken ONLY on the telemetry path
    /// (which is off by default) - never on the proven decode/pace path when the
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
            self.logDir = dir
            self.isoStamp = isoStamp
            guard self.openSegment() else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.flushQueue)
            timer.schedule(deadline: .now() + Self.flushInterval, repeating: Self.flushInterval,
                           leeway: .milliseconds(50))
            timer.setEventHandler { [weak self] in self?.flush() }
            self.flushTimer = timer
            timer.resume()
        }
    }

    /// Open the next trace SEGMENT (`telemetry-frames-<iso>.ndjson` for the first,
    /// `-<n>.ndjson` after a rollover), reset the byte count, and prune so only
    /// the last `maxTraceFiles` segments of this session survive. flushQueue-only.
    /// Returns false (and logs) if the file can't be opened.
    private func openSegment() -> Bool {
        guard let dir = logDir else { return false }
        let suffix = rolloverIndex == 0 ? "" : "-\(rolloverIndex)"
        let url = dir.appendingPathComponent("telemetry-frames-\(isoStamp)\(suffix).ndjson")
        FileManager.default.createFile(atPath: url.path, contents: nil)
        do {
            fileHandle = try FileHandle(forWritingTo: url)
        } catch {
            log.error("Telemetry frames: could not open file: \(error.localizedDescription, privacy: .public)")
            return false
        }
        log.notice("Telemetry per-frame trace → \(url.path, privacy: .public)")
        bytesWritten = 0
        rolloverIndex += 1
        segmentURLs.append(url)
        // Keep only the last K segments of THIS session - drop the oldest.
        while segmentURLs.count > Self.maxTraceFiles {
            let stale = segmentURLs.removeFirst()
            try? FileManager.default.removeItem(at: stale)
        }
        return true
    }

    /// Close the current segment and open the next - the size-cap rollover.
    /// flushQueue-only (called from `drainLocked` after a write crosses the cap).
    private func rollover() {
        try? fileHandle?.close()
        fileHandle = nil
        _ = openSegment()
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
    /// under a short lock. No I/O here. Bounded - drops oldest on overflow.
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
            log.error("Telemetry per-frame trace buffer overflowed (disk too slow?) - oldest lines dropped")
        }
        guard !batch.isEmpty, let fileHandle else { return }
        let blob = batch.joined(separator: "\n") + "\n"
        guard let data = blob.data(using: .utf8) else { return }
        do {
            try fileHandle.write(contentsOf: data)
            bytesWritten &+= UInt64(data.count)
            // Past the size cap: close + reopen a fresh segment, pruning so only
            // the last K survive. One rollover per drain (the batch is at most one
            // flush interval's frames, far below the cap), so the file can never
            // overshoot by more than a single batch.
            if bytesWritten >= Self.maxFileBytes { rollover() }
        } catch {
            log.error("Telemetry per-frame trace write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
