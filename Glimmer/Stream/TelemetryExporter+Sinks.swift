//
//  TelemetryExporter+Sinks.swift
//
//  Everything the exporter WRITES OUT, as opposed to what it samples: the
//  one-shot session-report scorecard written at stop, the "that felt bad"
//  bookmark row, the process-global engine EVENT sink (with its pre-start
//  buffer, so a row minted before the exporter exists is not lost), and the
//  NDJSON file sink itself. Split out of TelemetryExporter.swift (pure move,
//  same file-split idiom as the rest of the telemetry rig) to keep both units
//  under the length limit; see that file for the exporter, the gate, and the
//  lifecycle that opens and closes these sinks.
//
//  EVERYTHING here runs on the exporter's serial `workQueue` (or hops onto it),
//  never a hot path - `recordEvent` is the one any-thread entry point, and it
//  guards the exporter slot behind its own lock before hopping.
//

import Foundation
import os

extension TelemetryExporter {

    // MARK: - Session report (signal 5b) - one-shot scorecard on stop

    /// Build + write the one-shot session report next to the NDJSON file:
    /// `telemetry-session-<ISO>.json`. Duration, p50/p95/p99 per latency stage +
    /// glass-to-glass + input-to-photon, fps stats, event counts, worst windows,
    /// peak depth, build SHA. One glanceable scorecard per run. On `workQueue`
    /// (called from `stop()`), so the file write is serialized with the capture
    /// timer that already cancelled above.
    /// Module-internal (not private) so `stop()` in TelemetryExporter.swift
    /// still triggers the one-shot write across the file split.
    func writeSessionReport() {
        guard let ndjsonURL else { return }
        let now = DispatchTime.now()
        let durationSeconds =
            Double(now.uptimeNanoseconds &- connectInstant.uptimeNanoseconds) / 1_000_000_000.0
        // Final cumulative histograms (session-wide) for the percentiles. nil if
        // the latency rig never recorded a frame this session.
        let histograms = FrameTimingTracker.shared?.histograms.snapshot()
        let report = SessionReport(
            sessionId: sessionId,
            client: TelemetryRenderer.clientNameRaw,
            host: serverLabel,
            buildCommit: BuildInfo.commit,
            buildDate: BuildInfo.date,
            generatedISO8601: isoFormatter.string(from: Date()),
            durationSeconds: durationSeconds,
            aggregate: sessionAggregate,
            histograms: histograms,
            counters: counters)
        let json = report.renderJSON()
        let reportURL = ndjsonURL
            .deletingLastPathComponent()
            .appendingPathComponent("telemetry-session-\(isoFormatter.string(from: Date())).json")
        do {
            try json.data(using: .utf8)?.write(to: reportURL)
            log.notice("Telemetry session report → \(reportURL.path, privacy: .public)")
            Diag.notice("Telemetry SESSION REPORT written → \(reportURL.lastPathComponent) "
                + "(duration \(String(format: "%.1f", durationSeconds))s).", Self.logCategory)
        } catch {
            log.error("Telemetry session report write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - Bookmark ("that felt bad") - signal 4

    /// Record a user bookmark: the client-only chord fired during the stream to
    /// flag jank. Bumps the always-live `bookmark_total` counter (so a dashboard
    /// `increase()` marks the beat), and writes an explicit EVENT line into the
    /// NDJSON + the Diag log with the connect-relative time so a review jumps
    /// straight to the moment. Safe to call from the main actor (the chord fires
    /// on the input thread) - the file write hops onto `workQueue`, the same
    /// queue the 1Hz capture uses, so NDJSON lines never interleave mid-write.
    /// No-op-safe before the file is open (the line is simply dropped, the counter
    /// still increments).
    func recordBookmark() {
        counters.bookmarkTotal.increment()
        let now = DispatchTime.now()
        let sinceConnect =
            Double(now.uptimeNanoseconds &- connectInstant.uptimeNanoseconds) / 1_000_000_000.0
        let count = counters.bookmarkTotal.value
        Diag.notice(String(format: "BOOKMARK #%llu at t+%.3fs - user flagged jank "
            + "(\"that felt bad\")", count, sinceConnect), Self.logCategory)
        workQueue.async { [weak self] in
            guard let self else { return }
            let iso = self.isoFormatter.string(from: Date())
            // Explicit event object; `event` + `kind` keys distinguish it from the
            // per-second sample lines so a reader/grep finds bookmarks instantly.
            let line = "{\"ts\":\"\(iso)\",\"session\":\"\(self.sessionId)\","
                + "\"event\":\"bookmark\",\"kind\":\"felt_bad\","
                + String(format: "\"t_connect_s\":%.3f,", sinceConnect)
                + "\"bookmark_total\":\(count)}"
            self.appendNDJSON(line)
        }
    }

    // MARK: - Engine EVENT sink (audio_ttf / audio_pending)

    /// Process-global handle for EVENT rows from engine components that have no
    /// Engine EVENT sink: installed by `start()`, cleared by `stop()`, read by
    /// `recordEvent` from any thread - so `eventSinkBox` guards the slot (an
    /// unsynchronized load racing the teardown release would be a use-after-free).
    /// Module-internal (not private) so the lifecycle in TelemetryExporter.swift
    /// installs/clears the slot across the file split.
    static let eventSinkBox = OSAllocatedUnfairLock<TelemetryExporter?>(initialState: nil)

    /// Bounded holding pen for EVENT rows that fire BEFORE the exporter's sink
    /// is installed. The audio receiver spins up mid-handshake while the
    /// exporter starts only once the connection is up - so a warm host's
    /// one-shot `audio_ttf` lost the race BY CONSTRUCTION (by tens of ms) and
    /// the row vanished from the NDJSON + scorecard. Rows buffer here with their
    /// true event time and flush when `start()` opens the file.
    /// Bounded (events are rare one-shots; a cap of 64 is ~10x the realistic
    /// pre-start population) and CLEARED at every connect edge, so a row from a
    /// dead session can never flush into the next one - and when telemetry is
    /// off the pen holds at most one session's stragglers, a few hundred bytes.
    /// Module-internal (not private) only because `preStartEvents` below is - a
    /// private type cannot back an internal property.
    final class PreStartEventBuffer: @unchecked Sendable {
        static let maxBuffered = 64
        private let lock = NSLock()
        private var buffered: [(date: Date, fields: [String])] = []

        func append(_ fields: [String]) {
            lock.lock(); defer { lock.unlock() }
            guard buffered.count < Self.maxBuffered else { return }
            buffered.append((Date(), fields))
        }
        func drain() -> [(date: Date, fields: [String])] {
            lock.lock(); defer { lock.unlock() }
            let out = buffered
            buffered = []
            return out
        }
        func clear() { lock.lock(); buffered = []; lock.unlock() }
    }
    // Module-internal (not private) so `start()` in TelemetryExporter.swift can
    // drain the pen the moment an exporter comes up, across the file split.
    static let preStartEvents = PreStartEventBuffer()

    /// Forget any buffered pre-start EVENT rows. Called at the CONNECT edge
    /// (`StreamSession.anchorTelemetryConnectStart`) so the pen only ever holds
    /// rows belonging to the session being started.
    static func resetPreStartEventBuffer() { preStartEvents.clear() }

    /// Append one EVENT row to the live session's telemetry NDJSON from anywhere
    /// in the engine. Stamps the same `ts` + `session` header keys the
    /// bookmark/handshake event rows carry, then the caller's `"key":value`
    /// fields (the first should be the `"event":"..."` discriminator). Thread-safe
    /// from any thread: the row is rendered + written on the exporter's
    /// `workQueue` - the same hop `recordBookmark` makes - so NDJSON lines never
    /// interleave mid-write. Before the sink is installed the row is BUFFERED
    /// (see `PreStartEventBuffer`) and flushed at `start()`, so a pre-start
    /// one-shot is no longer lost; no-op-safe before the file is open.
    static func recordEvent(_ fields: [String]) {
        guard let exporter = eventSinkBox.withLock({ $0 }) else {
            preStartEvents.append(fields)
            return
        }
        exporter.workQueue.async { [weak exporter] in
            guard let exporter else { return }
            let header = "\"ts\":\"\(exporter.isoFormatter.string(from: Date()))\","
                + "\"session\":\"\(exporter.sessionId)\","
            exporter.appendNDJSON("{" + header + fields.joined(separator: ",") + "}")
        }
    }

    // MARK: - NDJSON sink

    /// Module-internal (not private) so `start()` in TelemetryExporter.swift
    /// still opens the file across the file split.
    func openNDJSONFile() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Glimmer", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            log.error("Telemetry: could not create log dir: \(error.localizedDescription, privacy: .public)")
            return
        }
        // C2: prune the Logs dir BEFORE creating this session's file (so the
        // newest files - this session's siblings - always survive). A fresh trio
        // of files was minted every session and never pruned; over months that
        // dir grows without bound (the per-frame trace alone is ~1.5GB/6h before
        // the rollover above caps it). Bounded by a total-byte budget + an age
        // limit, newest-kept.
        Self.sweepLogsDirectory(dir, log: log)
        // ISO8601 with ':' is filename-legal on APFS; keep the full timestamp so
        // each session's file is unique and sorts chronologically.
        let stamp = isoFormatter.string(from: Date())
        let url = dir.appendingPathComponent("telemetry-\(stamp).ndjson")
        ndjsonURL = url
        FileManager.default.createFile(atPath: url.path, contents: nil)
        do {
            fileHandle = try FileHandle(forWritingTo: url)
            log.notice("Telemetry NDJSON → \(url.path, privacy: .public)")
        } catch {
            log.error("Telemetry: could not open NDJSON file: \(error.localizedDescription, privacy: .public)")
        }
    }

    func appendNDJSON(_ line: String) {
        guard let fileHandle else { return }
        guard let data = (line + "\n").data(using: .utf8) else { return }
        do {
            try fileHandle.write(contentsOf: data)
        } catch {
            // A write failure (disk full, file removed) shouldn't take down the
            // stream - drop the line and keep going.
            log.error("Telemetry NDJSON write failed: \(error.localizedDescription, privacy: .public)")
        }
    }
}
