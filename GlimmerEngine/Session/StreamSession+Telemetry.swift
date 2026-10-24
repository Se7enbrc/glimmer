// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

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
    /// connection is up and the decoder/backend are live. Tests pass `enabled` and `make`.
    package func startTelemetryExporter(
        decoder: VideoDecoder, serverName: String, enabled: Bool = TelemetryGate.isEnabled,
        readPresentation: @MainActor @Sendable (SessionPresentation?, String)
            -> ((@Sendable () -> RendererPerformanceSource?)?, String) = { presentation, fallback in
                (presentation?.rendererProbe, presentation?.displayMode ?? fallback)
            },
        make: ((TelemetrySource, String) -> TelemetryExporter?)? = nil
    ) async {
        guard enabled else { return }
        // Capture the decoder weakly; its telemetry accessors are all
        // `nonisolated` + lock-guarded, so the exporter's utility queue can call
        // them directly. RTT / ENet health route through the decoder's LIVE
        // backend (re-pointed on reconnect) - a by-value backend capture here
        // went dead after a silent reconnect swapped the backend.
        let generation = telemetryGeneration
        let attempt = attemptID
        let preparedPresentation = presentation
        let fallbackDisplayMode = services.defaultDisplayMode
        let snapshot = await MainActor.run {
            readPresentation(preparedPresentation, fallbackDisplayMode)
        }
        guard generation == telemetryGeneration, attempt == attemptID, !stopInProgress, !publicTerminal else { return }
        let rendererProbe: @Sendable () -> RendererPerformanceSource?
        if let prepared = snapshot.0 { rendererProbe = prepared } else { rendererProbe = { nil } }
        let displayMode = snapshot.1
        var capture = services.makeCapture()
        capture.configuration.attemptID = attempt
        let source = TelemetrySource(
            videoStats: { [weak decoder] in
                decoder?.telemetryStatsSnapshot() ?? StreamStatsSnapshot()
            },
            decoderDrops: { [weak decoder] in decoder?.telemetryDecoderDrops() ?? 0 },
            backpressureDrops: { [weak decoder] in decoder?.telemetryBackpressureDrops() ?? 0 },
            presentationLateDrops: { [weak decoder] in decoder?.telemetryPresentationLateDrops() ?? 0 },
            presentationGaps: { [weak decoder] in decoder?.telemetryPresentationGaps() ?? 0 },
            estimatedRtt: { [weak decoder] in decoder?.telemetryEstimatedRtt() },
            enetHealth: { [weak decoder] in decoder?.telemetryEnetHealth() },
            pacingLiveness: { [weak decoder] in decoder?.telemetryPacingLiveness() },
            inFlightDecodeBacklog: { [weak decoder] in decoder?.inFlightDecodeBacklog() ?? 0 },
            refreshWindow: { [weak decoder] in decoder?.telemetryRefreshWindow() },
            displayProbe: { [weak decoder] in decoder?.telemetryDisplayProbe() },
            rendererProbe: rendererProbe,
            // The mode the session STARTED in (a Path-B Space exit can land it
            // in a window later; the per-second rows don't re-state it).
            displayMode: displayMode,
            // The decoder's setup ran during the connect, so the shape is negotiated.
            stream: StreamTelemetryConfig(
                width: Int(decoder.streamWidth), height: Int(decoder.streamHeight),
                fps: Int(decoder.streamFps), codec: VideoDecoder.codecLabel(for: decoder.streamVideoFormat),
                bitrate: reconnectConfig?.bitrateDecision),
            capture: capture)

        guard let exporter = (make ?? services.makeExporter)(source, serverName) else {
            // Gate off - the default. Nothing allocated, nothing started.
            return
        }
        self.telemetryExporter = exporter
        exporter.start()
        services.bookmarkHint()
    }

    /// Reset telemetry and anchor the P2 handshake timeline at the connect START
    /// edge, before any receiver can latch a one-shot. A session's first connect
    /// resets everything; an in-place reconnect keeps the totals and first handshake.
    package func anchorTelemetryConnectStart(hostAddress: String) {
        TelemetryCounters.shared.anchorConnectStart(
            now: TelemetryCounters.monotonicNowNanos(), reconnecting: isReconnecting)
        if !isReconnecting {
            // Isolates the launch-path leg (click → connect-start); no-op without a click.
            ConnectTimingTelemetry.shared.markConnectStart()
        }
        // Pre-start EVENT pen: anything still buffered belongs to a dead
        // session - forget it so this session's exporter can't flush it.
        TelemetryExporter.resetPreStartEventBuffer()
        // Latch the host for the stream-route probe (stream_link/stream_if):
        // the exporter is built long after the address is known, so the
        // connect edge hands it over (one String store, always-live).
        services.latchHost(hostAddress)
    }

    /// Called only from GENUINE teardown (user stop / watchdog / connect failure).
    /// Latches the per-session reason ordinal (first concrete wins) and bumps the
    /// process-global tally once. Always-live; no-op-safe.
    package func noteTelemetryDisconnect(_ reason: DisconnectReason) {
        // Bump the global once, keyed by the latched reason (a host terminate may
        // have latched it first). The per-terminate latch deliberately does NOT
        // count, so a recovered silent-reconnect blip never inflates the tally.
        let p2 = TelemetryCounters.shared.p2
        p2.setDisconnectReason(reason)
        if let latched = p2.countGlobalReasonOnce() {
            TelemetryCounters.shared.disconnectByReason.increment(latched)
        }
    }

    /// Preserve the input-time bookmark across the session actor hop; telemetry-off is a no-op.
    package func recordTelemetryBookmark(at time: DispatchTime = .now(), date: Date = Date()) {
        guard let exporter = telemetryExporter else { return }
        let marker = exporter.recordBookmark(at: time, date: date)
        audioDecoder.requestOutputDiagnostic(bookmark: marker)
    }

    /// Stop + drop the telemetry exporter, if one is running. Idempotent. Called
    /// from `stop()` teardown.
    package func stopTelemetryExporter() {
        telemetryGeneration &+= 1
        telemetryExporter?.stop()
        telemetryExporter = nil
    }
}
