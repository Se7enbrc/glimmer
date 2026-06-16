//
//  TelemetryExporter.swift
//
//  Opt-in, zero-overhead-when-off performance telemetry for the native streaming
//  engine. The point of this rig is to diagnose + tune the pipeline: when enabled
//  it exposes the full picture — fps triple, decode-time percentiles, present
//  cadence, recv-jitter, FEC recovery, ENet reliable-stream health, pacing depth,
//  drops-by-cause, input rate, CPU/threads, plus monotonic event counters and a
//  sampled latency breakdown — at a 1Hz cadence, with a connect-relative timestamp
//  + session id so the INITIAL-CONNECTION phase is fully visible.
//
//  GATING (default OFF). Enabled by EITHER:
//    * UserDefaults bool `telemetryEnabled` == true, OR
//    * environment GLIMMER_TELEMETRY=1.
//  When OFF, `TelemetryExporter.makeIfEnabled` returns nil and NOTHING is
//  allocated/started — no listener, no timer, no file, and the snapshot provider
//  is never invoked, so there is no per-frame and no per-tick cost. The
//  per-event counters (`TelemetryCounters`) are unconditional integer adds at
//  already-rare event sites (an IDR request, a lost frame), well under a
//  microsecond and orders of magnitude below any pacing budget — they cost
//  nothing measurable whether or not the exporter is running.
//
//  SAFETY (load-bearing):
//    * The HTTP endpoint binds LOOPBACK by default (and only ever when telemetry
//      is opt-in ENABLED — default OFF ⇒ no listener at all). The LAN bind
//      (0.0.0.0, IPv4) needs the SECOND opt-in defaults key `telemetryListenLAN`:
//      it lets a LOCAL monitoring container/pod (one scraping over a host bridge,
//      where traffic never arrives on loopback) reach `/metrics`, at the cost of
//      exposing live perf/input-rate telemetry to any LAN host.
//      No auth is added (auth on a debug-gated metrics port is its own attack
//      surface, and the data carries no secrets).
//    * Telemetry contains ONLY performance numbers. NEVER secrets, keys, tokens,
//      pairing material, or host credentials. The session id is a random opaque
//      tag, not a host identifier.
//    * A busy port is tolerated: we log + skip the listener (the NDJSON sink
//      still runs), and never crash the stream.
//
//  TWO SINKS, ONE SNAPSHOT:
//    1. A tiny HTTP server (Network.framework `NWListener`, port 9847) serving
//       `GET /metrics` in Prometheus text exposition format.
//    2. One NDJSON line per ~1s appended to
//       ~/Library/Logs/Glimmer/telemetry-<ISO8601>.ndjson (dir created).
//  Both render the SAME `TelemetrySnapshot`, captured once per second on a
//  dedicated serial queue — the StatsCollector read reuses its existing lock
//  (no second hot-path lock is added).
//

import Foundation
import Network
import os

// MARK: - Gating

/// Resolves the opt-in gate ONCE per process-relevant check. Kept tiny + free of
/// any allocation so the OFF path is a pure boolean read.
enum TelemetryGate {
    /// True iff telemetry should run. Either the UserDefaults flag or the env
    /// var enables it; default OFF. Read at session start only.
    static var isEnabled: Bool {
        if ProcessInfo.processInfo.environment["GLIMMER_TELEMETRY"] == "1" {
            return true
        }
        return UserDefaults.standard.bool(forKey: "telemetryEnabled")
    }
}

// The process-global event counters + activity gauges this exporter snapshots
// (`TelemetryCounters`) live in TelemetryCounters.swift — they are always-live
// (not gated) and shared across the engine, so they are kept in their own unit.

// MARK: - Exporter

/// Owns the all-interfaces HTTP server + NDJSON writer + 1Hz capture timer for one
/// streaming session. Created (only) when the gate is on; torn down on stream
/// teardown. `@unchecked Sendable`: all mutable state lives on `workQueue`.
final class TelemetryExporter: @unchecked Sendable {

    static let port: UInt16 = 9847
    static let logCategory = "Telemetry"
    /// Second opt-in (see SAFETY): bind 0.0.0.0 so a monitoring pod can scrape.
    static let lanBindDefaultsKey = "telemetryListenLAN"
    /// How long an accepted `/metrics` connection may live before the sweep
    /// cancels it. A scrape is over in milliseconds — even a badly jittered
    /// link finishes orders of magnitude inside this, and a swept slow scraper
    /// just reconnects next scrape; a peer silent for 10s is a port-scan hold
    /// or a half-open corpse (keepalive off ⇒ no error ever fires).
    static let connectionDeadlineSeconds: TimeInterval = 10
    private let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "Stream.Telemetry")

    /// LAN-bind opt-in, resolved ONCE at construction (the TelemetryGate
    /// read-at-session-start discipline — no mid-session bind tearing).
    private let lanBindEnabled = UserDefaults.standard.bool(forKey: lanBindDefaultsKey)

    let source: TelemetrySource
    let counters = TelemetryCounters.shared

    /// Wi-Fi radio sampler (signal 3). Exists only on the gate-on path (this
    /// exporter is built only when enabled), and is read once per ~1Hz capture
    /// tick on `workQueue` — never the hot path. Reads the CURRENT association
    /// only (no scan), so it can't disrupt the link.
    let wifi = WiFiTelemetry()

    /// Stream-ROUTE probe: which interface the stream's packets actually
    /// traverse (`stream_link`/`stream_if`), as opposed to the association
    /// sampler above which describes the Wi-Fi RADIO whether or not the stream
    /// rides it. Gate-on construction only; probes on its own utility queue
    /// (started in `start()`, path-monitor re-probes + route_change events),
    /// read lock-guarded once per capture tick. This field gates the env-signal
    /// adaptive layer, so it must be the ROUTE truth, not the radio truth.
    let route = StreamRouteProbe()

    /// PRESENT/DISPLAY sampler (P1): EDR-headroom trend + HDR-engaged + screen +
    /// ProMotion. Its main-actor 1Hz timer is built ONLY on the gate-on path (see
    /// `start()`), so when telemetry is off nothing is constructed or scheduled.
    /// The exporter reads its lock-guarded snapshot on `workQueue` each tick.
    let display: DisplayTelemetry

    /// P1 RESOURCE: SoC P-cluster vs E-cluster active-residency sampler (IOReport).
    /// Built ONLY on the gate-on path; nil if IOReport is unavailable on this OS
    /// (then we simply omit the cluster-residency series). Sampled once per ~1Hz
    /// capture tick on `workQueue` — never a hot path. The per-PROCESS per-thread
    /// half of the RESOURCE signal is a stateless `ResourceTelemetry.sample()` read
    /// (no stored sampler needed).
    let ioReport = IOReportSampler()

    /// Set once the one-shot QoS audit has been logged (it runs on the first
    /// capture tick, when a per-thread sample exists). Confined to `workQueue`.
    var qosAuditDone = false

    /// Single serial queue: capture, listener-connection handling, file append.
    /// Everything mutable is confined here so no extra locks are needed.
    let workQueue = DispatchQueue(label: "io.ugfugl.Glimmer.telemetry", qos: .utility)

    private var listener: NWListener?
    /// Accepted `/metrics` connections still alive, so the per-connection
    /// deadline and teardown can sweep silent/half-open peers — cancel() used
    /// to be reachable ONLY from inside the receive completion, so a never-
    /// sending peer leaked its NWConnection + FD forever. `workQueue`-confined.
    private var openConnections: [ObjectIdentifier: NWConnection] = [:]
    var captureTimer: DispatchSourceTimer?
    private var fileHandle: FileHandle?

    let sessionId: String
    /// Sunshine server name for this session (the `host` label). Set once at
    /// construction; copied onto every snapshot in capture.
    let serverLabel: String
    let connectInstant = DispatchTime.now()

    /// Last rendered Prometheus body, served to any `GET /metrics`. Replaced each
    /// capture tick so a scrape always sees fresh-within-1s numbers without us
    /// having to capture on the scrape thread. Written on `workQueue` by the
    /// capture path (see TelemetryExporter+Capture.swift); read on the same queue
    /// by the HTTP handler.
    var latestPrometheus: String = "# no sample yet\n"

    /// Previous-tick monotonic totals + wall-clock, so the capture derives the
    /// per-second rates (pkts/s, input events/s, flush/s) from deltas. Confined to
    /// `workQueue` (the capture path is the only reader/writer).
    var prevPacketsTotal: UInt64 = 0
    var prevFramesTotal: UInt64 = 0
    var prevFecRecoveredTotal: UInt64 = 0
    var prevInputEventsTotal: UInt64 = 0
    var prevInputFlushTotal: UInt64 = 0
    var prevCaptureTime: DispatchTime?
    /// Previous-tick P1 receive-quality totals, so the per-second loss / OOO / dup
    /// RATES come from deltas against the received-packets delta (same model as
    /// pkts/s + fec-rate above).
    var prevPreFecLostTotal: UInt64 = 0
    var prevOutOfOrderTotal: UInt64 = 0
    var prevDuplicateTotal: UInt64 = 0
    /// Previous-tick stale-frame-repeat total, so the per-second repeats RATE
    /// (the invisible-stutter signal) comes from a delta over the tick interval.
    var prevStaleFrameRepeatTotal: UInt64 = 0
    /// Previous-tick P1 AUDIO totals, so the per-second audio pkts/s + loss / FEC
    /// recovery / under-run / over-run RATES come from deltas (same model as the
    /// video receive-quality + stale-repeat rates). Confined to `workQueue`.
    var prevAudioPacketsTotal: UInt64 = 0
    var prevAudioPacketsLostTotal: UInt64 = 0
    var prevAudioFecRecoveredTotal: UInt64 = 0
    var prevAudioUnderrunTotal: UInt64 = 0
    var prevAudioOverrunTotal: UInt64 = 0
    /// Previous-tick P2 corruption-heuristic total, so the per-second corruption
    /// RATE comes from a delta over the tick interval (same model as the other
    /// per-second event rates). Confined to `workQueue`.
    var prevCorruptionTotal: UInt64 = 0
    /// True once the one-shot CONNECT-HANDSHAKE breakdown EVENT line has been
    /// written to the NDJSON, so it is emitted exactly once per session (the moment
    /// the first decoded frame completes the timeline). Confined to `workQueue`.
    var handshakeEventWritten = false

    /// Running per-session aggregate for the one-shot SESSION REPORT (signal 5b),
    /// updated each capture tick on `workQueue` and rendered to a scorecard JSON
    /// at stop. Confined to `workQueue` (same as everything else here).
    var sessionAggregate = SessionAggregate()
    /// The NDJSON file URL, kept so the session report lands next to it.
    private var ndjsonURL: URL?

    let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    // MARK: - Construction

    /// Returns a ready-to-`start()` exporter iff the opt-in gate is on; nil
    /// otherwise (the default), so the caller allocates NOTHING when off.
    static func makeIfEnabled(source: TelemetrySource, serverName: String) -> TelemetryExporter? {
        guard TelemetryGate.isEnabled else { return nil }
        return TelemetryExporter(source: source, serverName: serverName)
    }

    private init(source: TelemetrySource, serverName: String) {
        self.source = source
        // The Sunshine server this session streams from — the `host` label
        // (vs `client` = this Mac). Falls back to "unknown" so the series is
        // never label-less. See TelemetryExporter+Render.swift.
        self.serverLabel = serverName.isEmpty ? "unknown" : serverName
        // 64-bit random hex — opaque, not a host identifier.
        self.sessionId = String(format: "%016x", UInt64.random(in: .min ... .max))
        // The DISPLAY sampler reads the main-actor probe from the source. Built
        // here (the exporter itself is only constructed on the gate-on path), so
        // its main-queue timer is armed in `start()` and never exists when off.
        self.display = DisplayTelemetry(probe: source.displayProbe)
    }

    // MARK: - Lifecycle

    /// Start both sinks. Opens the NDJSON file, binds the all-interfaces listener
    /// (tolerating a busy port), and arms the 1Hz capture. All on `workQueue`.
    /// NOTE: the per-session counter reset does NOT happen here anymore — it
    /// moved to the CONNECT edge (`StreamSession.anchorTelemetryConnectStart`),
    /// BEFORE the receivers spin up. Resetting here ran AFTER a warm host's
    /// audio had already latched its TTF, which both wiped the fresh record
    /// (empty scorecard) and let the pre-reset latch return the PRIOR session's
    /// values (the chimeric audio_ttf with a byte-identical stale span).
    func start() {
        workQueue.async { [weak self] in
            guard let self else { return }
            // Per-frame latency tracker + its batched trace writer. Installs the
            // gate-checked `FrameTimingTracker.shared` the hot-path stage call
            // sites read; when the gate is off (default) nothing is installed and
            // those sites stay zero-cost. Started here so the latency rig shares
            // the exporter's lifecycle, session id, and ISO stamp.
            FrameTimingTracker.startIfEnabled(
                sessionId: self.sessionId, isoStamp: self.isoFormatter.string(from: Date()))
            self.openNDJSONFile()
            // One-shot CONFIG/DIAL breadcrumb first, so every session file is
            // self-describing from line 1 (see writeConfigEvent).
            self.writeConfigEvent()
            // Install the engine EVENT sink so components with no handle to this
            // exporter (the audio receiver) can land event rows in the NDJSON.
            // Gate-on path only (this whole exporter is), cleared in `stop()`.
            Self.eventSink = self
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
            // Fresh ENV-SIGNAL session: state machine to CLEAR, session-relative
            // radio baselines + evidence runs emptied. On this workQueue — the
            // same confinement as the capture ticks that will feed it (the
            // first of which is at least a second away, so nothing races).
            EnvSignalController.shared.resetForNewSession()
            self.startListener()
            self.startCaptureTimer()
            // Arm the PRESENT/DISPLAY sampler (P1): a MAIN-queue 1Hz timer reading
            // EDR/HDR/screen/ProMotion. Gate-on path only (this whole exporter is),
            // so off-path it is never scheduled.
            self.display.start()
            // Arm the stream-route probe (first sample + NWPathMonitor re-probes).
            self.route.start()
            self.log.notice("Telemetry exporter started (session \(self.sessionId, privacy: .public))")
            let bind = self.lanBindEnabled ? "0.0.0.0" : "127.0.0.1"
            let scope = self.lanBindEnabled ? "all-interfaces" : "loopback-only"
            Diag.notice("Telemetry exporter ON — http://\(bind):\(Self.port)/metrics + NDJSON log "
                + "(session \(self.sessionId)). Opt-in diagnostics; \(scope) bind "
                + "(defaults key `\(Self.lanBindDefaultsKey)`).", Self.logCategory)
        }
    }

    /// Stop both sinks. Idempotent. Cancels the timer + listener and closes the
    /// file. Synchronous on `workQueue` so teardown order is deterministic.
    func stop() {
        workQueue.sync { [weak self] in
            guard let self else { return }
            // Clear the engine EVENT sink first: a row posted after this lands
            // in the pre-start pen (cleared at the next connect edge) instead
            // of racing the file close below.
            Self.eventSink = nil
            self.captureTimer?.cancel()
            self.captureTimer = nil
            self.listener?.cancel()
            self.listener = nil
            // Sweep still-open /metrics connections (silent/half-open peers
            // whose receive completion will never fire) — no FD outlives stop.
            for connection in self.openConnections.values { connection.cancel() }
            self.openConnections.removeAll()
            // Stop the DISPLAY sampler's main-queue timer (idempotent).
            self.display.stop()
            // Stop the route probe's path monitor (idempotent).
            self.route.stop()
            // One-shot SESSION REPORT (signal 5b) — written BEFORE tearing the
            // latency tracker down so it can read the final cumulative histograms
            // for the session-wide p50/p95/p99. A glanceable scorecard per run.
            self.writeSessionReport()
            try? self.fileHandle?.close()
            self.fileHandle = nil
            // Tear down the latency tracker: clears `FrameTimingTracker.shared`
            // (returning the hot path to zero-cost) and flushes + closes the
            // per-frame trace writer.
            FrameTimingTracker.stop()
            self.log.notice("Telemetry exporter stopped (session \(self.sessionId, privacy: .public))")
        }
    }

    // MARK: - Session report (signal 5b) — one-shot scorecard on stop

    /// Build + write the one-shot session report next to the NDJSON file:
    /// `telemetry-session-<ISO>.json`. Duration, p50/p95/p99 per latency stage +
    /// glass-to-glass + input-to-photon, fps stats, event counts, worst windows,
    /// peak depth, build SHA. One glanceable scorecard per run. On `workQueue`
    /// (called from `stop()`), so the file write is serialized with the capture
    /// timer that already cancelled above.
    private func writeSessionReport() {
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

    // MARK: - Bookmark ("that felt bad") — signal 4

    /// Record a user bookmark: the client-only chord fired during the stream to
    /// flag jank. Bumps the always-live `bookmark_total` counter (so a dashboard
    /// `increase()` marks the beat), and writes an explicit EVENT line into the
    /// NDJSON + the Diag log with the connect-relative time so a review jumps
    /// straight to the moment. Safe to call from the main actor (the chord fires
    /// on the input thread) — the file write hops onto `workQueue`, the same
    /// queue the 1Hz capture uses, so NDJSON lines never interleave mid-write.
    /// No-op-safe before the file is open (the line is simply dropped, the counter
    /// still increments).
    func recordBookmark() {
        counters.bookmarkTotal.increment()
        let now = DispatchTime.now()
        let sinceConnect =
            Double(now.uptimeNanoseconds &- connectInstant.uptimeNanoseconds) / 1_000_000_000.0
        let count = counters.bookmarkTotal.value
        Diag.notice(String(format: "BOOKMARK #%llu at t+%.3fs — user flagged jank "
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
    /// path to this session's exporter instance: the bookmark chord reaches
    /// `recordBookmark` through StreamSession (which owns the exporter), but the
    /// audio receiver sits behind the native backend with no such owner chain.
    /// `start()` installs the live exporter, `stop()` clears it — the same
    /// install/clear + `nonisolated(unsafe)` single-writer discipline as
    /// `FrameTimingTracker.shared` (written only at session start/teardown, read
    /// at rare event sites). nil whenever telemetry is off (the exporter is never
    /// built), so an off-path emitter pays one optional load and nothing else.
    nonisolated(unsafe) private static var eventSink: TelemetryExporter?

    /// Bounded holding pen for EVENT rows that fire BEFORE the exporter's sink
    /// is installed. The audio receiver spins up mid-handshake while the
    /// exporter starts only once the connection is up — so a warm host's
    /// one-shot `audio_ttf` lost the race BY CONSTRUCTION (by tens of ms) and
    /// the row vanished from the NDJSON + scorecard. Rows buffer here with their
    /// true event time and flush when `start()` opens the file.
    /// Bounded (events are rare one-shots; a cap of 64 is ~10x the realistic
    /// pre-start population) and CLEARED at every connect edge, so a row from a
    /// dead session can never flush into the next one — and when telemetry is
    /// off the pen holds at most one session's stragglers, a few hundred bytes.
    private final class PreStartEventBuffer: @unchecked Sendable {
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
    private static let preStartEvents = PreStartEventBuffer()

    /// Forget any buffered pre-start EVENT rows. Called at the CONNECT edge
    /// (`StreamSession.anchorTelemetryConnectStart`) so the pen only ever holds
    /// rows belonging to the session being started.
    static func resetPreStartEventBuffer() { preStartEvents.clear() }

    /// Append one EVENT row to the live session's telemetry NDJSON from anywhere
    /// in the engine. Stamps the same `ts` + `session` header keys the
    /// bookmark/handshake event rows carry, then the caller's `"key":value`
    /// fields (the first should be the `"event":"…"` discriminator). Thread-safe
    /// from any thread: the row is rendered + written on the exporter's
    /// `workQueue` — the same hop `recordBookmark` makes — so NDJSON lines never
    /// interleave mid-write. Before the sink is installed the row is BUFFERED
    /// (see `PreStartEventBuffer`) and flushed at `start()`, so a pre-start
    /// one-shot is no longer lost; no-op-safe before the file is open.
    static func recordEvent(_ fields: [String]) {
        guard let exporter = eventSink else {
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

    private func openNDJSONFile() {
        let dir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/Glimmer", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        } catch {
            log.error("Telemetry: could not create log dir: \(error.localizedDescription, privacy: .public)")
            return
        }
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
            // stream — drop the line and keep going.
            log.error("Telemetry NDJSON write failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    // MARK: - HTTP listener (loopback by default; LAN bind is a second opt-in)

    private func startListener() {
        let params = NWParameters.tcp
        // LOOPBACK BY DEFAULT: a debug gate alone should not put a live
        // perf/input-rate endpoint on every interface. The wide bind (0.0.0.0,
        // for a local monitoring container/pod scraping over a host bridge,
        // where traffic never arrives on 127.0.0.1) now requires the SECOND
        // opt-in `telemetryListenLAN` (see SAFETY in the header). IPv4 stays
        // pinned either way so the endpoint is the familiar `:9847`.
        if !lanBindEnabled {
            params.requiredInterfaceType = .loopback
        }
        params.allowLocalEndpointReuse = true
        if let inetOptions = params.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options {
            inetOptions.version = .v4
        }
        guard let endpointPort = NWEndpoint.Port(rawValue: Self.port) else { return }
        do {
            let newListener = try NWListener(using: params, on: endpointPort)
            newListener.stateUpdateHandler = { [weak self] state in
                guard let self else { return }
                switch state {
                case .failed(let error):
                    // Busy port (or any bind failure): log + skip. The NDJSON
                    // sink still runs; the stream is never affected.
                    // swiftlint:disable:next line_length
                    self.log.error("Telemetry HTTP listener failed (port \(Self.port) busy?): \(error.localizedDescription, privacy: .public) — skipping HTTP, NDJSON continues")
                    Diag.warn("Telemetry HTTP endpoint unavailable (port \(Self.port) likely busy); "
                        + "NDJSON log continues.", Self.logCategory)
                    self.listener?.cancel()
                    self.listener = nil
                case .ready:
                    // swiftlint:disable:next line_length
                    self.log.notice("Telemetry HTTP ready on \(self.lanBindEnabled ? "0.0.0.0" : "127.0.0.1", privacy: .public):\(Self.port)")
                default:
                    break
                }
            }
            newListener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }
            newListener.start(queue: workQueue)
            listener = newListener
        } catch {
            // swiftlint:disable:next line_length
            log.error("Telemetry: NWListener init failed: \(error.localizedDescription, privacy: .public) — skipping HTTP, NDJSON continues")
        }
    }

    /// Minimal HTTP/1.1 handling: read the request, serve `/metrics` (or 404),
    /// close. We do not keep connections alive — a scraper reconnects per scrape,
    /// which is the Prometheus default and keeps this server trivially simple.
    /// Every accepted connection is TRACKED + deadline-swept (silent/half-open
    /// peers never fire the receive completion); closes funnel through `finishConnection`.
    private func handleConnection(_ connection: NWConnection) {
        let key = ObjectIdentifier(connection)
        openConnections[key] = connection
        connection.start(queue: workQueue)
        // Receive deadline: still tracked after this long ⇒ swept. The closure
        // holds the connection strongly for the deadline span — bounded by design.
        workQueue.asyncAfter(deadline: .now() + Self.connectionDeadlineSeconds) { [weak self] in
            guard let self, self.openConnections[key] != nil else { return }
            self.finishConnection(connection)
        }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 4096) { [weak self] data, _, _, error in
            guard let self else { connection.cancel(); return }
            if error != nil { self.finishConnection(connection); return }
            let request = data.flatMap { String(data: $0, encoding: .utf8) } ?? ""
            let response: String
            if request.hasPrefix("GET /metrics") {
                let body = self.latestPrometheus
                response = "HTTP/1.1 200 OK\r\n"
                    + "Content-Type: text/plain; version=0.0.4; charset=utf-8\r\n"
                    + "Content-Length: \(body.utf8.count)\r\n"
                    + "Connection: close\r\n\r\n"
                    + body
            } else {
                let body = "404 not found — try GET /metrics\n"
                response = "HTTP/1.1 404 Not Found\r\n"
                    + "Content-Type: text/plain; charset=utf-8\r\n"
                    + "Content-Length: \(body.utf8.count)\r\n"
                    + "Connection: close\r\n\r\n"
                    + body
            }
            let payload = Data(response.utf8)
            connection.send(content: payload, completion: .contentProcessed { [weak self] _ in
                guard let self else { connection.cancel(); return }
                self.finishConnection(connection)
            })
        }
    }

    /// Cancel + untrack one accepted connection. On `workQueue` (every caller
    /// already is). Idempotent — a double finish is a map miss + harmless cancel.
    private func finishConnection(_ connection: NWConnection) {
        openConnections.removeValue(forKey: ObjectIdentifier(connection))
        connection.cancel()
    }

    // The 1Hz capture timer + the snapshot-assembly path (capture / the P1
    // receive-quality rate derivation / the auxiliary-signal fill) live in
    // TelemetryExporter+Capture.swift, split out to keep this unit focused on the
    // listener/timer/file lifecycle and stay under the file-length budget. They run
    // on `workQueue`, the same serial context as everything else here.
}
