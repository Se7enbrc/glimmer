// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  LogStore.swift
//
//  The troubleshooting log: a ring the in-app viewer reads, mirrored to os_log and
//  the session file. Private values reach only the viewer; os_log and the file,
//  which people attach to issues, show "<private>".
//

import Foundation
import os
import Synchronization

extension Array where Element == String {
    mutating func trimOldestOverflow(maxCount: Int) {
        guard count > maxCount else { return }
        removeFirst(count - maxCount / 2)
    }
}

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
    /// The message with private values as "<private>"; nil when nothing in it was private.
    let redactedMessage: String?

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss.SSS"
        return formatter
    }()

    var timeString: String { Self.timeFormatter.string(from: date) }

    /// Plain one-line form, full detail.
    var plain: String { "\(timeString)  \(level.label.uppercased())  [\(category)]  \(message)" }

    /// What Copy puts on the pasteboard: copied lines end up in public issues, like the session file.
    var shareable: String {
        "\(timeString)  \(level.label.uppercased())  [\(category)]  \(redactedMessage ?? message)"
    }
}

/// O(1) ring under a short lock; the viewer reads newest-last snapshots. Each session's
/// opening lines stay pinned so 1 Hz health lines can't evict the connect, codec and route.
final class LogStore: Sendable {
    static let shared = LogStore()

    private struct Ring {
        var entries: [LogEntry] = []
        /// The oldest entry once `entries` is full, and the next one overwritten.
        var head = 0
        var pinned: [LogEntry] = []
        var nextID: UInt64 = 0
    }

    private let capacity: Int
    private let pinnedCapacity: Int
    private let state = Mutex(Ring())
    private let captureDebug: Atomic<Bool>

    init(capacity: Int = 2000, pinnedCapacity: Int = 200,
         captureDebug: Bool = UserDefaults.standard.bool(forKey: "diagFileLogDebug")) {
        self.capacity = capacity
        self.pinnedCapacity = pinnedCapacity
        self.captureDebug = Atomic(captureDebug)
    }

    func log(_ level: LogLevel, _ diag: DiagMessage, category: String) {
        let redacted = diag.systemLogText
        mirrorToSystemLog(level, redacted, category: category)
        // A debug flood stays out of the ring and the file unless verbose capture is on.
        guard level > .debug || captureDebug.load(ordering: .relaxed) else { return }
        let date = Date()
        state.withLock { ring in
            let entry = LogEntry(id: ring.nextID, date: date, level: level, category: category, message: diag.text,
                                 redactedMessage: redacted == diag.text ? nil : redacted)
            ring.nextID &+= 1
            if ring.entries.count < capacity {
                ring.entries.append(entry)
            } else {
                ring.entries[ring.head] = entry
                ring.head = (ring.head + 1) % capacity
            }
            if ring.pinned.count < pinnedCapacity { ring.pinned.append(entry) }
        }
        // The session file gets the redacted line: people attach it to public issues.
        SessionLogFileSink.shared?.append(level: level, category: category, message: redacted)
    }

    /// Private values are already "<private>" here, so .public keeps the wording greppable.
    private func mirrorToSystemLog(_ level: LogLevel, _ redacted: String, category: String) {
        let logger = Logger(subsystem: "io.ugfugl.Glimmer", category: category)
        switch level {
        case .debug: logger.debug("\(redacted, privacy: .public)")
        case .info: logger.info("\(redacted, privacy: .public)")
        case .notice: logger.notice("\(redacted, privacy: .public)")
        case .warning: logger.warning("\(redacted, privacy: .public)")
        case .error: logger.error("\(redacted, privacy: .public)")
        }
    }

    /// A stream is starting: pin its opening lines in place of the last session's, and
    /// resolve verbose capture once, the way the session file does.
    func beginSession(captureDebug debug: Bool = UserDefaults.standard.bool(forKey: "diagFileLogDebug")) {
        captureDebug.store(debug, ordering: .relaxed)
        state.withLock { $0.pinned.removeAll(keepingCapacity: true) }
    }

    /// Newest-last: pinned lines the ring has since dropped, then the ring in order.
    func snapshot() -> [LogEntry] {
        state.withLock { ring in
            let oldestKept = ring.entries.isEmpty ? UInt64.max : ring.entries[ring.head].id
            var out = Array(ring.pinned.prefix { $0.id < oldestKept })
            out += ring.entries[ring.head...]
            out += ring.entries[..<ring.head]
            return out
        }
    }

    func clear() {
        state.withLock { ring in
            ring.entries.removeAll(keepingCapacity: true)
            ring.head = 0
            ring.pinned.removeAll()
        }
    }
}

/// Terse façade: `Diag.info("Connecting to \(address, privacy: .private)", "Stream")`.
/// Interpolations take Logger's `privacy:` argument and default to public; a
/// private value reaches only the in-app viewer, never the system log or session file.
enum Diag {
    static func debug(_ message: DiagMessage, _ category: String) { LogStore.shared.log(.debug, message, category: category) }
    static func info(_ message: DiagMessage, _ category: String) { LogStore.shared.log(.info, message, category: category) }
    static func notice(_ message: DiagMessage, _ category: String) { LogStore.shared.log(.notice, message, category: category) }
    static func warn(_ message: DiagMessage, _ category: String) { LogStore.shared.log(.warning, message, category: category) }
    static func error(_ message: DiagMessage, _ category: String) { LogStore.shared.log(.error, message, category: category) }
}

/// Logger's spelling, so a Diag line reads like the `log` line beside it.
enum DiagPrivacy: Sendable {
    case `public`, `private`
}

/// One Diag line in two renderings: `text` for the in-app viewer and its export,
/// `systemLogText` for os_log and the session file. The redacted copy is built
/// only once a private value appears.
struct DiagMessage: ExpressibleByStringInterpolation, Sendable {
    let text: String
    private let redacted: String?

    var systemLogText: String { redacted ?? text }

    init(stringLiteral value: String) {
        text = value
        redacted = nil
    }

    init(stringInterpolation: StringInterpolation) {
        text = stringInterpolation.text
        redacted = stringInterpolation.redacted
    }

    private init(text: String, redacted: String?) {
        self.text = text
        self.redacted = redacted
    }

    /// Long lines wrap with `+`; each piece keeps its own private values.
    static func + (lhs: DiagMessage, rhs: DiagMessage) -> DiagMessage {
        let redacted = lhs.redacted == nil && rhs.redacted == nil ? nil : lhs.systemLogText + rhs.systemLogText
        return DiagMessage(text: lhs.text + rhs.text, redacted: redacted)
    }

    struct StringInterpolation: StringInterpolationProtocol {
        fileprivate var text = ""
        fileprivate var redacted: String?

        init(literalCapacity: Int, interpolationCount: Int) {
            text.reserveCapacity(literalCapacity + interpolationCount * 8)
        }

        mutating func appendLiteral(_ literal: String) {
            text += literal
            redacted? += literal
        }

        mutating func appendInterpolation<Value>(_ value: Value, privacy: DiagPrivacy = .public) {
            let rendered = String(describing: value)
            switch privacy {
            case .public:
                redacted? += rendered
            case .private:
                if redacted == nil { redacted = text }
                redacted? += "<private>"
            }
            text += rendered
        }

        /// A nested line keeps its own private values, or goes private whole, instead
        /// of rendering as a struct dump.
        mutating func appendInterpolation(_ message: DiagMessage, privacy: DiagPrivacy = .public) {
            if redacted == nil, privacy == .private || message.redacted != nil { redacted = text }
            redacted? += privacy == .private ? "<private>" : message.systemLogText
            text += message.text
        }
    }
}

// MARK: - Per-session file sink (gate-checked, buffered, off the hot path)

/// While a telemetry session runs, mirrors Diag's redacted text (INFO+, DEBUG with
/// `diagFileLogDebug`) to Logs/Glimmer. `@unchecked Sendable`: the lock guards
/// `pending`; the file and timer live on `flushQueue`, so loggers never touch disk.
final class SessionLogFileSink: @unchecked Sendable {

    /// Gate-checked singleton, non-nil only while a telemetry/debug session has it
    /// installed. `sharedBox` guards the slot: an unsynchronized load racing
    /// teardown's release of the previous sink would be an ARC use-after-free.
    private static let sharedBox = OSAllocatedUnfairLock<SessionLogFileSink?>(initialState: nil)
    static var shared: SessionLogFileSink? { sharedBox.withLock { $0 } }

    /// Install a fresh sink iff the caller's gate is on; off, nothing is installed
    /// and the logging path pays one nil load.
    static func startIfEnabled(enabled: Bool, directory: URL = TelemetryExporter.logsDirectory) {
        guard enabled else { return }
        // Check-and-install under the lock so concurrent enables can't both create
        // a sink. open() runs off-lock; it only dispatches onto flushQueue.
        let sink: SessionLogFileSink? = sharedBox.withLock { box in
            guard box == nil else { return nil }
            let created = SessionLogFileSink()
            box = created
            return created
        }
        sink?.open(in: directory)
    }

    /// Tear down + clear the singleton. Flushes whatever is pending and closes the
    /// file, so the per-session log is complete. Idempotent.
    static func stop() {
        // Take the sink out of the slot (releasing the box's strong ref) before
        // closing off-lock, so no reader observes a half-released reference.
        let sink = sharedBox.withLock { box -> SessionLogFileSink? in
            let previous = box
            box = nil
            return previous
        }
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

    /// INFO+ by default: a per-ACK DEBUG line once made up most of a session file.
    /// Immutable, so the check is a plain compare on the logging path.
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
    private func open(in dir: URL) {
        flushQueue.async { [weak self] in
            guard let self else { return }
            let timer = DispatchSource.makeTimerSource(queue: self.flushQueue)
            timer.schedule(deadline: .now() + Self.flushInterval, repeating: Self.flushInterval,
                           leeway: .milliseconds(50))
            timer.setEventHandler { [weak self] in self?.flush() }
            self.flushTimer = timer
            timer.resume()

            do {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            } catch {
                self.log.error("Diag file sink: could not create log dir: \(error.localizedDescription, privacy: .private)")
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
                self.log.notice("Diag file sink → \(url.lastPathComponent, privacy: .public)")
            } catch {
                self.log.error("Diag file sink: could not open file: \(error.localizedDescription, privacy: .private)")
                return
            }
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
            pending.trimOldestOverflow(maxCount: Self.maxPendingLines)
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
            log.error("Diag file sink write failed: \(error.localizedDescription, privacy: .private)")
        }
    }
}
