//
//  StreamSession+Telemetry.swift
//
//  Wires the opt-in `TelemetryExporter` onto a live session. Split out of
//  StreamSession.swift so the gating + reader-closure construction lives in one
//  focused unit; see TelemetryExporter.swift for the exporter itself and the
//  gate/safety contract.
//
//  GATING: the exporter is built ONLY when the opt-in gate is on (default OFF),
//  so a normal session allocates NOTHING here and there is no per-tick cost. The
//  reader closures are `@Sendable` and capture the live backend + decoder so the
//  exporter's own background queue never reaches into actor-isolated state.
//

import Foundation

extension StreamSession {

    /// Build + start the telemetry exporter iff enabled. No-op (and no
    /// allocation) when the gate is off. Called from `start()` once the
    /// connection is up and the decoder/backend are live.
    func startTelemetryExporter(decoder: VideoDecoder, serverName: String) {
        // Diag file sink is opened earlier, at the connect-start anchor (see
        // anchorTelemetryConnectStart), so the RTSP/ENet handshake - including
        // the `RTSP negotiated codec=...` line - is captured in the file and
        // shipped with the rest of the logs. This call is a no-op backstop
        // (startIfEnabled is idempotent) for any path that reaches the exporter
        // without having gone through the anchor.
        SessionLogFileSink.startIfEnabled(enabled: TelemetryGate.isEnabled)

        // Capture the decoder weakly; its telemetry accessors are all
        // `nonisolated` + lock-guarded, so the exporter's utility queue can call
        // them directly. RTT / ENet health route through the decoder's LIVE
        // backend (re-pointed on reconnect) - a by-value backend capture here
        // went dead after a silent reconnect swapped the backend.
        let source = TelemetrySource(
            videoStats: { [weak decoder] in
                decoder?.telemetryStatsSnapshot() ?? StreamStatsSnapshot()
            },
            decoderDrops: { [weak decoder] in decoder?.telemetryDecoderDrops() ?? 0 },
            backpressureDrops: { [weak decoder] in decoder?.telemetryBackpressureDrops() ?? 0 },
            presentationLateDrops: { [weak decoder] in decoder?.telemetryPresentationLateDrops() ?? 0 },
            estimatedRtt: { [weak decoder] in decoder?.telemetryEstimatedRtt() },
            enetHealth: { [weak decoder] in decoder?.telemetryEnetHealth() },
            pacingLiveness: { [weak decoder] in decoder?.telemetryPacingLiveness() },
            inFlightDecodeBacklog: { [weak decoder] in decoder?.inFlightDecodeBacklog() ?? 0 },
            refreshWindow: { [weak decoder] in decoder?.telemetryRefreshWindow() },
            displayProbe: { [weak decoder] in decoder?.telemetryDisplayProbe() })

        guard let exporter = TelemetryExporter.makeIfEnabled(source: source, serverName: serverName) else {
            // Gate off - the default. Nothing allocated, nothing started.
            return
        }
        self.telemetryExporter = exporter
        exporter.start()
        // Discoverability (signal 4): log the bookmark chord on stream start so the
        // user knows how to flag jank. Logged only when telemetry is ON - that's
        // when a bookmark is actionable (it writes into the live telemetry). The
        // default ⌃B is the simple two-key chord (vs the quit/stats ⌃⌥ family) -
        // easy to hit mid-jank; the displayString renders the glyphs.
        Diag.notice("Telemetry bookmark chord = \(HotkeyChord.defaultBookmark.displayString) "
            + "- press it any time the stream \"feels bad\" to drop a timestamped jank "
            + "marker (client-only; never sent to the host).", TelemetryExporter.logCategory)
    }

    /// Reset ALL session-scoped telemetry state + anchor the P2 CONNECT-HANDSHAKE
    /// timeline, at the connect START edge - BEFORE `startConnection` spins the
    /// receivers up. The reset lives HERE, not in the exporter's `start()`
    /// (which runs only once the connection is established): a warm host's
    /// audio latches its one-shot TTF mid-handshake, so an exporter-time reset
    /// ran AFTER the latch - wiping the fresh record from the scorecard while
    /// the pre-reset latch had already served the PRIOR session's values into
    /// the event row (the chimeric byte-identical connect_to_decoded_ms).
    /// Resetting at this edge makes every one-shot latch (audio TTF, first-
    /// packet gauge, the socket-open fallback anchor) start clean before any
    /// receiver can race it. Always-live; when telemetry is off nothing reads
    /// the state, so this is a few harmless stores at the rarest site there is
    /// (one connect).
    func anchorTelemetryConnectStart(hostAddress: String) {
        TelemetryCounters.shared.resetForNewSession()
        // Open the Diag file sink HERE - at connect-start, before
        // startConnection runs the RTSP/ENet handshake - so the handshake and
        // the `RTSP negotiated codec=...` line land in the file and get shipped.
        // Previously it opened with the exporter (post-connect), so the entire
        // negotiation phase was missing from shipped logs. Same opt-in gate;
        // idempotent; torn down in stopTelemetryExporter.
        SessionLogFileSink.startIfEnabled(enabled: TelemetryGate.isEnabled)
        // Pre-start EVENT pen: anything still buffered belongs to a dead
        // session - forget it so this session's exporter can't flush it.
        TelemetryExporter.resetPreStartEventBuffer()
        // Latch the host for the stream-route probe (stream_link/stream_if):
        // the exporter is built long after the address is known, so the
        // connect edge hands it over (one String store, always-live).
        StreamRouteProbe.latchHost(hostAddress)
        let p2 = TelemetryCounters.shared.p2
        p2.reset()
        p2.anchorConnectStart(TelemetryCounters.monotonicNowNanos())
    }

    /// Called only from GENUINE teardown (user stop / watchdog / connect failure).
    /// Latches the per-session reason ordinal (first concrete wins) and bumps the
    /// process-global tally once. Always-live; no-op-safe.
    func noteTelemetryDisconnect(_ reason: DisconnectReason) {
        // Bump the global once, keyed by the latched reason (a host terminate may
        // have latched it first). The per-terminate latch deliberately does NOT
        // count, so a recovered silent-reconnect blip never inflates the tally.
        let p2 = TelemetryCounters.shared.p2
        p2.setDisconnectReason(reason)
        if let latched = p2.countGlobalReasonOnce() {
            TelemetryCounters.shared.disconnectByReason.increment(latched)
        }
    }

    /// Record a "that felt bad" telemetry bookmark (signal 4). Actor-isolated so
    /// the `onBookmarkHotkey` closure can read the actor-isolated exporter via a
    /// `Task` hop. No-op when telemetry is off (`telemetryExporter` is nil) - the
    /// chord is still consumed in the input path, it simply records nothing.
    func recordTelemetryBookmark() {
        telemetryExporter?.recordBookmark()
    }

    /// Stop + drop the telemetry exporter, if one is running. Idempotent. Called
    /// from `stop()` teardown.
    func stopTelemetryExporter() {
        telemetryExporter?.stop()
        telemetryExporter = nil
        // Flush + close the per-session Diag file sink (idempotent; no-op if it
        // was never installed). Done last so any teardown Diag lines are captured.
        SessionLogFileSink.stop()
    }
}
