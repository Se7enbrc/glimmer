//
//  LogStore.swift
//
//  In-app ring buffer for a Sunshine-style troubleshooting log.
//
//  Why not just read os_log? `OSLogStore(scope: .currentProcessIdentifier)` is
//  not reliably readable from inside the App Sandbox on this platform - the
//  Troubleshooting log viewer came up empty even though os_log was emitting.
//  So the canonical troubleshooting record is THIS in-memory ring buffer, which
//  the viewer reads directly. Every entry is ALSO mirrored to os_log (.public -
//  callers pass already-redacted strings, same discipline as the rest of the
//  app) so Console.app and `log stream` keep working for live debugging.
//

import Foundation
import os

/// Severity for the in-app troubleshooting log. Ordered so the viewer's level
/// filter can do `entry.level >= threshold`.
enum LogLevel: Int, Comparable, Sendable, CaseIterable {
    case debug = 0
    case info
    case notice
    case warning
    case error

    static func < (lhs: LogLevel, rhs: LogLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    var label: String {
        switch self {
        case .debug: return "Debug"
        case .info: return "Info"
        case .notice: return "Notice"
        case .warning: return "Warning"
        case .error: return "Error"
        }
    }
}

/// One entry in the troubleshooting log.
struct LogEntry: Identifiable, Sendable {
    let id: UInt64
    let date: Date
    let level: LogLevel
    let category: String
    let message: String

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var timeString: String { Self.timeFormatter.string(from: date) }

    /// Plain one-line form for copy/export.
    var plain: String { "\(timeString)  \(level.label.uppercased())  [\(category)]  \(message)" }
}

/// Thread-safe ring buffer. Entries arrive from many threads (stream callbacks,
/// the backend's connection listener, controller handlers); reads happen on the
/// main thread (the viewer). Guarded by one lock; the mirror-to-os_log happens
/// outside the lock so logging never serialises hot paths against each other.
final class LogStore: @unchecked Sendable {
    static let shared = LogStore()

    private let lock = NSLock()
    private var buffer: [LogEntry] = []
    private var nextID: UInt64 = 0
    private let capacity = 2000

    private init() { buffer.reserveCapacity(capacity) }

    func log(_ level: LogLevel, _ message: String, category: String) {
        lock.lock()
        let id = nextID
        nextID &+= 1
        buffer.append(LogEntry(id: id, date: Date(), level: level, category: category, message: message))
        if buffer.count > capacity { buffer.removeFirst(buffer.count - capacity) }
        lock.unlock()

        // Mirror to os_log so Console / `log stream` still see everything live.
        // Messages are already redacted by the caller, so .public is correct.
        let logger = Logger(subsystem: "io.ugfugl.Glimmer", category: category)
        switch level {
        case .debug: logger.debug("\(message, privacy: .public)")
        case .info: logger.info("\(message, privacy: .public)")
        case .notice: logger.notice("\(message, privacy: .public)")
        case .warning: logger.warning("\(message, privacy: .public)")
        case .error: logger.error("\(message, privacy: .public)")
        }

        // Third sink (gate-checked, default OFF): when telemetry/debug is enabled
        // for a streaming session, ALSO mirror the line to a per-session text file
        // so the rich os_log/Diag record - not just the telemetry NDJSON - is
        // persisted and shippable into a remote log sink. The
        // append is a single optional load when off (no file, no lock, no
        // allocation) and, when on, only pushes a pre-rendered line into an
        // in-memory buffer drained by a background timer - never an I/O (or fsync)
        // on the producing thread, so a slow disk can never serialise a hot-path
        // logger against the file. Mirrors the FrameTraceWriter discipline.
        if let sink = SessionLogFileSink.shared {
            sink.append(level: level, category: category, message: message)
        }
    }

    /// Newest-last snapshot for the viewer.
    func snapshot() -> [LogEntry] {
        lock.lock(); defer { lock.unlock() }
        return buffer
    }

    func clear() {
        lock.lock(); buffer.removeAll(keepingCapacity: true); lock.unlock()
    }
}

/// Terse façade for call sites. `Diag.info("stream connected", "Stream")`.
enum Diag {
    static func debug(_ message: String, _ category: String) { LogStore.shared.log(.debug, message, category: category) }
    static func info(_ message: String, _ category: String) { LogStore.shared.log(.info, message, category: category) }
    static func notice(_ message: String, _ category: String) { LogStore.shared.log(.notice, message, category: category) }
    static func warn(_ message: String, _ category: String) { LogStore.shared.log(.warning, message, category: category) }
    static func error(_ message: String, _ category: String) { LogStore.shared.log(.error, message, category: category) }
}

// MARK: - Per-session file sink (gate-checked, buffered, off the hot path)

/// Buffered background file sink that mirrors the Diag/os_log stream to a
/// per-session text file when telemetry/debug is enabled. This is the THIRD sink
/// on `LogStore.log` (after the in-memory ring buffer and os_log): it persists the
/// rich runtime log to `~/Library/Logs/Glimmer/glimmer-<ISO8601>.log` (which, in
/// the App Sandbox, resolves to the container's
/// `Data/Library/Logs/Glimmer` - the SAME directory the telemetry NDJSON writer
/// uses, so a log shipper can mount one folder and tail both `*.log`
/// and `*.ndjson`).
///
/// GATING + HOT-PATH SAFETY (load-bearing - same contract as the telemetry rig):
///   * `SessionLogFileSink.shared` is nil unless the telemetry/debug gate is on
///     and a session installed it. Every `LogStore.log` call pays a single
///     nil-optional load when off - NO file, NO lock, NO allocation.
///   * LEVEL THRESHOLD (log diet): the file mirrors INFO+ by default. Testing
///     measured 30-105k lines/hr in this file - 76% of one wireless run's log
///     was a single per-ACK DEBUG pattern - burying the real signal
///     (underrun edges, env transitions, breadcrumbs) that postmortems grep
///     for. The RING BUFFER and os_log still carry EVERY level (live debugging
///     loses nothing); only the durable per-session file is dieted. DEBUG
///     opt-in via the Diagnostics-pane defaults key `diagFileLogDebug`,
///     resolved ONCE at install - the TelemetryGate read-at-session-start
///     discipline, so a mid-session flip can't tear one file's level.
///   * When ON, the producing thread only formats one line and pushes it into an
///     in-memory buffer under a short `os_unfair_lock`. NEVER an I/O on the
///     producing thread: a ~250ms background timer drains the buffer to disk in
///     one write, and the sink never fsyncs. A slow disk can only grow the
///     (bounded) buffer, never stall a logging hot path.
///   * The buffer is bounded; on overflow the OLDEST pending lines are dropped
///     (and the drop is noted once), so a wedged disk can never grow it unbounded.
///   * Torn down with the session (`stop()` flushes + closes), so the file is
///     complete and the gate returns to zero-cost.
///
/// SECRET-FREE by inheritance: callers already redact before calling Diag (the
/// same `.public` discipline the os_log mirror relies on), so the file carries
/// only what is already safe to print.
///
/// `@unchecked Sendable`: the pending buffer is `os_unfair_lock`-guarded; the file
/// handle + flush timer are confined to `flushQueue`.
final class SessionLogFileSink: @unchecked Sendable {

    /// Gate-checked singleton. Non-nil ONLY while a telemetry/debug session has it
    /// installed; read on the (warm, not tight-inner-loop) logging path as
    /// `SessionLogFileSink.shared`. `nonisolated(unsafe)`: written only at session
    /// start/teardown (single writer, well-ordered against the reads), the same
    /// discipline `FrameTimingTracker.shared` uses.
    nonisolated(unsafe) static var shared: SessionLogFileSink?

    /// Install a fresh sink iff the gate is on. Called from the session's
    /// telemetry wiring. No-op (nothing installed, `shared` stays nil ⇒ hot path
    /// stays zero-cost) when off. The gate is resolved by the caller and passed in
    /// so this type has no dependency direction into the Stream module.
    static func startIfEnabled(enabled: Bool) {
        guard enabled else { return }
        guard shared == nil else { return }
        let sink = SessionLogFileSink()
        sink.open()
        shared = sink
    }

    /// Tear down + clear the singleton. Flushes whatever is pending and closes the
    /// file, so the per-session log is complete. Idempotent.
    static func stop() {
        let sink = shared
        shared = nil
        sink?.close()
    }

    // ---- Instance state (only exists when enabled) ----

    private static let flushInterval: DispatchTimeInterval = .milliseconds(250)
    /// ~10k lines at ~120 bytes/line ≈ 1.2MB - far past one flush interval's worth
    /// of log lines; overflow drops the OLDEST pending (stalest diagnostic data is
    /// the right thing to lose) and is logged once.
    private static let maxPendingLines = 10_000

    private let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "Diag.FileSink")
    private let flushQueue = DispatchQueue(label: "io.ugfugl.Glimmer.diag.filesink", qos: .utility)
    private var fileHandle: FileHandle?
    private var flushTimer: DispatchSourceTimer?

    private let bufferLock = os_unfair_lock_t.allocate(capacity: 1)
    private var pending: [String] = []
    private var droppedOverflow = false

    /// Minimum level mirrored to the FILE (see the LEVEL THRESHOLD note in the
    /// type doc). Immutable after init so the producing-thread check is a plain
    /// load + compare - no lock, no defaults read on the logging path.
    private let minimumLevel: LogLevel

    private let lineFormatter: DateFormatter = {
        let formatter = DateFormatter()
        // Millisecond wall-clock - same precision as the in-app viewer's
        // `timeString`, so a line in the file reads identically to one on screen.
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSSZ"
        return formatter
    }()

    private init() {
        bufferLock.initialize(to: os_unfair_lock_s())
        // Resolved once per sink (== per session): debug opt-in for deep-dive
        // sessions, INFO+ otherwise. Same defaults domain as `telemetryEnabled`.
        minimumLevel = UserDefaults.standard.bool(forKey: "diagFileLogDebug") ? .debug : .info
    }
    deinit { bufferLock.deallocate() }

    /// Open the per-session file + arm the flush timer. Mirrors the telemetry
    /// NDJSON path so both land in one directory a log shipper can mount.
    private func open() {
        flushQueue.async { [weak self] in
            guard let self else { return }
            let dir = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/Glimmer", isDirectory: true)
            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                self.log.error("Diag file sink: could not create log dir: \(error.localizedDescription, privacy: .public)")
                return
            }
            // ISO8601 with ':' is filename-legal on APFS; same stamp shape as the
            // telemetry NDJSON files, so a `glimmer-<stamp>.log` sorts next to its
            // `telemetry-<stamp>.ndjson` siblings.
            let iso = ISO8601DateFormatter()
            iso.formatOptions = [.withInternetDateTime]
            let stamp = iso.string(from: Date())
            let url = dir.appendingPathComponent("glimmer-\(stamp).log")
            FileManager.default.createFile(atPath: url.path, contents: nil)
            do {
                self.fileHandle = try FileHandle(forWritingTo: url)
                self.log.notice("Diag file sink → \(url.path, privacy: .public)")
            } catch {
                self.log.error("Diag file sink: could not open file: \(error.localizedDescription, privacy: .public)")
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
    /// teardown is deterministic and the file is complete when `stop()` returns.
    private func close() {
        flushQueue.sync { [weak self] in
            guard let self else { return }
            self.flushTimer?.cancel()
            self.flushTimer = nil
            self.drain()
            try? self.fileHandle?.close()
            self.fileHandle = nil
        }
    }

    /// Producing-thread side: format one line and push it into the buffer under a
    /// short lock. No I/O here. Bounded - drops oldest on overflow.
    func append(level: LogLevel, category: String, message: String) {
        // Level gate BEFORE formatting: a sub-threshold line costs one compare,
        // not a DateFormatter render - the per-ACK-class flood must not pay
        // string-building just to be discarded.
        guard level >= minimumLevel else { return }
        let line = "\(lineFormatter.string(from: Date()))  \(level.label.uppercased())  [\(category)]  \(message)"
        os_unfair_lock_lock(bufferLock)
        pending.append(line)
        if pending.count > Self.maxPendingLines {
            pending.removeFirst(pending.count - Self.maxPendingLines)
            droppedOverflow = true
        }
        os_unfair_lock_unlock(bufferLock)
    }

    private func flush() { drain() }

    /// Background drain: swap out the pending buffer under the lock, then write the
    /// batch in one go off the lock.
    private func drain() {
        os_unfair_lock_lock(bufferLock)
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        let overflowed = droppedOverflow
        droppedOverflow = false
        os_unfair_lock_unlock(bufferLock)

        if overflowed {
            log.error("Diag file sink buffer overflowed (disk too slow?) - oldest lines dropped")
        }
        guard !batch.isEmpty, let fileHandle else { return }
        let blob = batch.joined(separator: "\n") + "\n"
        guard let data = blob.data(using: .utf8) else { return }
        do {
            try fileHandle.write(contentsOf: data)
        } catch {
            log.error("Diag file sink write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
