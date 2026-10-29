// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

#if os(macOS)
// Opt-in, per-session telemetry: one 1 Hz snapshot feeds the local NDJSON file.
// The disabled path constructs no exporter, timers or files.

import Foundation
import os
import Darwin

/// Owns one session's NDJSON writer and capture timer.
/// All mutable state is confined to `workQueue`.
package final class TelemetryExporter: @unchecked Sendable {
    package static let logCategory = "Telemetry"
    package let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "Stream.Telemetry")

    package let source: TelemetrySource
    /// Allocated only when the opt-in exporter starts its capture timer.
    package var rendererTelemetry: RendererTelemetry?
    package let counters: TelemetryCounters
    /// The shell owns the destination so captures and retention always use the same directory.
    package let outputDirectory: URL

    /// Wi-Fi radio sampler (signal 3). Exists only on the gate-on path (this
    /// exporter is built only when enabled), and is read once per ~1Hz capture
    /// tick on `workQueue` - never the hot path. Reads the CURRENT association
    /// only (no scan), so it can't disrupt the link.

    /// Stream-ROUTE probe (`stream_link`/`stream_if`): the interface the stream's packets
    /// traverse, as opposed to the radio sampler above. Owned by EnvSignalController's always-on
    /// session feed so one path monitor serves both; nil between sessions.

    /// PRESENT/DISPLAY sampler (P1): EDR-headroom trend + HDR-engaged + screen +
    /// ProMotion. Its main-actor 1Hz timer is built ONLY on the gate-on path (see
    /// `start()`), so when telemetry is off nothing is constructed or scheduled.
    /// The exporter reads its lock-guarded snapshot on `workQueue` each tick.
    package let display: DisplayTelemetry

    /// P1 RESOURCE: SoC P-cluster vs E-cluster active-residency sampler (IOReport).
    /// The PROCESS-LIFETIME singleton, borrowed - never owned - because
    /// releasing IOReport's objects crashed 2026.8.15's teardown (see the
    /// PROCESS-LIFETIME note in IOReportSampler.swift). First gate-on access
    /// builds it, so telemetry-off still allocates nothing; `start()` resets
    /// its per-session baselines. nil if IOReport is unavailable on this OS
    /// (then we simply omit the cluster-residency series). Sampled once per
    /// ~1Hz capture tick on `workQueue` - never a hot path. The per-PROCESS
    /// per-thread half of the RESOURCE signal is a stateless
    /// `ResourceTelemetry.sample()` read (no stored sampler needed).

    /// Set once the one-shot QoS audit has been logged (it runs on the first
    /// capture tick, when a per-thread sample exists). Confined to `workQueue`.
    package var qosAuditDone = false

    /// Single serial queue: capture and file append.
    /// Everything mutable is confined here so no extra locks are needed.
    package let workQueue = DispatchQueue(label: "io.ugfugl.Glimmer.telemetry", qos: .utility)
    private let workQueueKey = DispatchSpecificKey<Bool>()
    package var captureTimer: DispatchSourceTimer?
    // Module-internal (not private) so the NDJSON sink in
    // TelemetryExporter+Sinks.swift owns open/append/close across the split.
    package var fileHandle: FileHandle?
    package var ndjsonRowsWritten: UInt64 = 0
    package var ndjsonRowsFailed: UInt64 = 0
    package var ndjsonWriteFailures: UInt64 = 0
    package var sessionReportURL: URL?
    package var stopped = false
    package var clockAnchorID: UInt64 = 0

    package let sessionId: String
    /// The PC's pseudonym for this session (the `host` label), copied onto every snapshot.
    package let serverLabel: String
    package let connectInstant = DispatchTime.now()

    /// Previous-tick monotonic totals + wall-clock, so the capture derives the
    /// per-second rates (pkts/s, input events/s, flush/s) from deltas. Confined to
    /// `workQueue` (the capture path is the only reader/writer).
    package var prevPacketsTotal: UInt64 = 0
    package var prevFramesTotal: UInt64 = 0
    package var prevFecRecoveredTotal: UInt64 = 0
    package var prevInputEventsTotal: UInt64 = 0
    package var prevInputFlushTotal: UInt64 = 0
    package var prevCaptureTime: DispatchTime?
    /// Previous-tick P1 receive-quality totals, so the per-second loss / OOO / dup
    /// RATES come from deltas against the received-packets delta (same model as
    /// pkts/s + fec-rate above).
    package var prevPreFecLostTotal: UInt64 = 0
    package var prevOutOfOrderTotal: UInt64 = 0
    package var prevDuplicateTotal: UInt64 = 0
    /// Previous-tick stale-frame-repeat total, so the per-second repeats RATE
    /// (the invisible-stutter signal) comes from a delta over the tick interval.
    package var prevStaleFrameRepeatTotal: UInt64 = 0
    /// Previous-tick P1 AUDIO totals, so the per-second audio pkts/s + loss / FEC
    /// recovery / under-run / over-run RATES come from deltas (same model as the
    /// video receive-quality + stale-repeat rates). Confined to `workQueue`.
    package var prevAudioPacketsTotal: UInt64 = 0
    package var prevAudioPacketsLostTotal: UInt64 = 0
    package var prevAudioFecRecoveredTotal: UInt64 = 0
    package var prevAudioUnderrunTotal: UInt64 = 0
    package var prevAudioOverrunTotal: UInt64 = 0
    /// Previous-tick P2 corruption-heuristic total, so the per-second corruption
    /// RATE comes from a delta over the tick interval (same model as the other
    /// per-second event rates). Confined to `workQueue`.
    package var prevCorruptionTotal: UInt64 = 0
    /// True once the one-shot CONNECT-HANDSHAKE breakdown EVENT line has been
    /// written to the NDJSON, so it is emitted exactly once per session (the moment
    /// the first decoded frame completes the timeline). Confined to `workQueue`.
    package var handshakeEventWritten = false

    /// Running per-session aggregate for the one-shot SESSION REPORT (signal 5b),
    /// updated each capture tick on `workQueue` and rendered to a scorecard JSON
    /// at stop. Confined to `workQueue` (same as everything else here).
    package var sessionAggregate = SessionAggregate()
    /// The NDJSON file URL, kept so the session report lands next to it.
    /// Module-internal (not private) so both writers - the NDJSON sink and
    /// the session report - reach it from TelemetryExporter+Sinks.swift.
    package var ndjsonURL: URL?

    package let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    // MARK: - Construction

    /// Returns a ready-to-`start()` exporter iff the opt-in gate is on; nil
    /// otherwise (the default), so the caller allocates NOTHING when off.
    package static func makeIfEnabled(source: TelemetrySource, serverName: String,
                                      outputDirectory: URL,
                                      enabled: Bool = TelemetryGate.isEnabled) -> TelemetryExporter? {
        guard enabled else { return nil }
        return TelemetryExporter(
            source: source, serverName: serverName,
            outputDirectory: outputDirectory)
    }

    /// Tests pass a temporary directory and their own counters.
    package init(source: TelemetrySource, serverName: String,
                 outputDirectory: URL, counters: TelemetryCounters = .shared) {
        self.source = source
        self.outputDirectory = outputDirectory
        self.counters = counters
        self.serverLabel = TelemetryRenderer.pseudonym(serverName)
        // 64-bit random hex - opaque, not a host identifier.
        self.sessionId = String(format: "%016x", UInt64.random(in: .min ... .max))
        // The DISPLAY sampler reads the main-actor probe from the source. Built
        // here (the exporter itself is only constructed on the gate-on path), so
        // its main-queue timer is armed in `start()` and never exists when off.
        self.display = DisplayTelemetry(probe: source.displayProbe)
        workQueue.setSpecific(key: workQueueKey, value: true)
    }

    // MARK: - Lifecycle

    /// Start local recording and samplers on the work queue.
    /// Counter resets belong to the connect edge, before receivers can latch first-frame timings.
    package func start() {
        workQueue.async { [weak self] in
            guard let self, !self.stopped else { return }
            // Reset the process-lifetime IOReport sampler's delta baselines for
            // THIS session - it survives across sessions by design (teardown
            // crash, see IOReportSampler.swift), so without this its first
            // "delta" would span the gap since the previous session's last tick.
            self.source.capture.beginSession()
            // NDJSON first: its budget sweep must run before the trace writer
            // creates this session's segment, or the sweep could delete it.
            self.openNDJSONFile()
            // Per-frame latency tracker + its batched trace writer. Installs the
            // gate-checked `FrameTimingTracker.shared` the hot-path stage call
            // sites read; when the gate is off (default) nothing is installed and
            // those sites stay zero-cost. Started here so the latency rig shares
            // the exporter's lifecycle, session id, and ISO stamp.
            FrameTimingTracker.startIfEnabled(
                sessionId: self.sessionId, isoStamp: self.isoFormatter.string(from: Date()),
                directory: self.outputDirectory, attemptID: self.source.capture.configuration.attemptID,
                diagnostic: self.source.capture.configuration.diagnosticBuild)
            // One-shot CONFIG/DIAL breadcrumb first, so every session file is
            // self-describing from line 1 (see writeConfigEvent).
            self.writeConfigEvent()
            // Install the engine EVENT sink so components with no handle to this
            // exporter (the audio receiver) can land event rows in the NDJSON.
            // Gate-on path only (this whole exporter is), cleared in `stop()`.
            Self.eventSinkBox.withLock { $0 = self }
            // Flush EVENT rows that fired BEFORE this exporter came up (a warm
            // host's audio_ttf beats the exporter by construction, losing its TTF
            // row by tens of ms). Each row keeps its true event-time stamp; the
            // buffer was cleared at this session's connect edge, so nothing here
            // can belong to a prior session.
            for event in Self.preStartEvents.drain() {
                let header = "\"ts\":\"\(self.isoFormatter.string(from: event.date))\","
                    + "\"session\":\"\(self.sessionId)\","
                self.appendNDJSON("{" + header + event.fields.joined(separator: ",") + "}")
            }
            self.startCaptureTimer()
            // Arm the PRESENT/DISPLAY sampler (P1): a MAIN-queue 1Hz timer reading
            // EDR/HDR/screen/ProMotion. Gate-on path only (this whole exporter is),
            // so off-path it is never scheduled.
            self.display.start()
            self.log.notice("Telemetry exporter started (session \(self.sessionId, privacy: .public))")
            Diag.notice("Telemetry recording started (session \(self.sessionId)).", Self.logCategory)
        }
    }

    /// Synchronous teardown without dispatching back onto an occupied work queue.
    /// Sampler cancellation never waits for its main-queue event handler.
    package func stop() {
        if DispatchQueue.getSpecific(key: workQueueKey) != nil {
            stopOnWorkQueue()
        } else {
            workQueue.sync { stopOnWorkQueue() }
        }
    }

    private func stopOnWorkQueue() {
        dispatchPrecondition(condition: .onQueue(workQueue))
        guard !stopped else { return }
        stopped = true
        // Clear the event sink before closing the file so later rows go to the pre-start buffer.
        Self.eventSinkBox.withLock { $0 = nil }
        captureTimer?.cancel()
        captureTimer = nil
        rendererTelemetry?.stop()
        rendererTelemetry = nil
        display.stop()
        // The report needs the final histograms before the tracker is removed.
        writeSessionReport()
        do {
            try fileHandle?.synchronize()
            try fileHandle?.close()
        } catch { ndjsonWriteFailures &+= 1 }
        fileHandle = nil
        FrameTimingTracker.stop()
        writeEvidenceManifest()
        log.notice("Telemetry exporter stopped (session \(self.sessionId, privacy: .public))")
    }

    // MARK: - C2 Logs-directory sweep

    /// Byte budget for the per-frame traces + 1Hz NDJSON in Logs/Glimmer,
    /// enforced at each diagnostics session start (before its files exist, so
    /// the session being recorded may exceed it).
    package static let logsByteBudget: UInt64 = 300 * 1024 * 1024
    /// Age limit (seconds): any Glimmer log file older than this is pruned,
    /// Diag logs and receipts included. 14 days.
    private static let logsMaxAgeSeconds: TimeInterval = 14 * 24 * 3600

    /// Age-only sweep at app launch, whatever the diagnostics setting, so the
    /// 14-day rule runs even when no diagnostics session ever starts again.
    package static func sweepLogsAtLaunch(directory: URL) {
        let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "Stream.Telemetry")
        Task.detached(priority: .utility) {
            sweepLogsDirectory(directory, log: log, enforceBudget: false)
        }
    }

    /// Prune the Glimmer Logs dir: age for every family, then (if `enforceBudget`) bytes over
    /// traces + 1Hz NDJSON, the latest session last. Diag logs + receipts only ever age out.
    package static func sweepLogsDirectory(_ dir: URL, log: Logger, enforceBudget: Bool = true) {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.creationDateKey, .contentModificationDateKey, .fileSizeKey, .isRegularFileKey]
        guard let entries = try? fm.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return }
        // Our own log families only - never delete a foreign file.
        let ours = entries.filter { url in
            let name = url.lastPathComponent
            return name.hasPrefix("telemetry-") || name.hasPrefix("glimmer-")
        }
        struct Entry { let url: URL; let created: Date; let modified: Date; let size: UInt64 }
        var files: [Entry] = []
        for url in ours {
            guard let values = try? url.resourceValues(forKeys: Set(keys)),
                  values.isRegularFile == true else { continue }
            files.append(Entry(url: url,
                               created: values.creationDate ?? .distantPast,
                               modified: values.contentModificationDate ?? .distantPast,
                               size: UInt64(values.fileSize ?? 0)))
        }
        let now = Date()
        var pruned = 0
        // (1) AGE prune.
        var survivors: [Entry] = []
        for entry in files {
            if now.timeIntervalSince(entry.modified) > logsMaxAgeSeconds {
                if (try? fm.removeItem(at: entry.url)) != nil { pruned += 1 }
            } else {
                survivors.append(entry)
            }
        }
        // (2) BYTE-BUDGET prune over the bulky families, latest session last. Within
        // each group: rollover segments, then base segments, then 1Hz, oldest-first.
        let bulky = survivors.filter {
            let name = $0.url.lastPathComponent
            return name.hasPrefix("telemetry-") && name.hasSuffix(".ndjson")
        }
        let family = { (entry: Entry) -> Int in
            let name = entry.url.lastPathComponent
            guard name.hasPrefix("telemetry-frames-") else { return 2 }
            return name.contains("Z-") ? 0 : 1
        }
        // The latest session is whatever was created at or after its 1Hz file,
        // which `start()` creates before the trace.
        let latestStart = bulky.filter { family($0) == 2 }.map(\.created).max() ?? .distantFuture
        let rank = { (entry: Entry) in
            (entry.created >= latestStart ? 1 : 0, family(entry), entry.modified)
        }
        var total = bulky.reduce(UInt64(0)) { $0 &+ $1.size }
        if enforceBudget && total > logsByteBudget {
            for entry in bulky.sorted(by: { rank($0) < rank($1) }) {
                guard total > logsByteBudget else { break }
                if (try? fm.removeItem(at: entry.url)) != nil {
                    total &-= entry.size
                    pruned += 1
                }
            }
        }
        if pruned > 0 {
            log.notice("Telemetry: swept \(pruned, privacy: .public) old log file(s) from Logs/Glimmer")
        }
    }
}

#endif
