//
//  TelemetryExporter+CaptureSections.swift
//
//  The per-section snapshot fills the 1Hz `capture()` tick drives, in tick
//  order: P1 AUDIO (the other stream), P2 SESSION-LIFECYCLE (+ the one-shot
//  handshake EVENT line), P1 PRESENT/DISPLAY, P1 RESOURCE (P-vs-E-core), and
//  the Track-A auxiliary signals. Split from TelemetryExporter+Capture.swift -
//  pure move (the FramePacer-split idiom) to keep that file under the
//  file-length budget; the timer, `capture()` itself, and the network/rate
//  derivation stay there, and the Extras sidecar + cross-tick baselines live
//  in TelemetryExporter+CaptureExtras.swift.
//
//  EVERYTHING here runs on the exporter's serial `workQueue` (never a hot
//  path): each fill reads the always-live counters/gauges the engine batches
//  into off the hot path. When the gate is off (default) this exporter is
//  never built, so none of this runs.
//

import Foundation

extension TelemetryExporter {

    /// Fill the P1 AUDIO block (the other stream): the monotonic receive +
    /// playout totals, the per-second rates derived from this tick's deltas, the
    /// published playout STATE (buffer fill + A/V sync drift - read once by
    /// `capture()` and passed in, shared with the Extras fill so one tick's
    /// fill and playout-target fields come from one stamp), and the one-shot
    /// cold-start first-packet time. On the exporter queue - never a hot path. The
    /// rates use the same delta-over-interval model as the video receive-quality +
    /// stale-repeat rates; each rate is emitted only when its denominator is
    /// non-zero so a silent (no-audio) tick doesn't publish a 0/0.
    func fillAudio(
        into snap: inout TelemetrySnapshot, now: DispatchTime,
        state: TelemetryCounters.AudioState?
    ) {
        var audio = AudioSnapshot()
        let packetsTotal = counters.audioPacketsTotal.value
        let lostTotal = counters.audioPacketsLostTotal.value
        let recoveredTotal = counters.audioFecRecoveredTotal.value
        let underrunTotal = counters.audioUnderrunTotal.value
        let overrunTotal = counters.audioOverrunTotal.value
        audio.packetsTotal = packetsTotal
        audio.packetsLostTotal = lostTotal
        audio.fecRecoveredTotal = recoveredTotal
        audio.underrunTotal = underrunTotal
        audio.overrunTotal = overrunTotal

        if let prev = prevCaptureTime {
            let dt = Double(now.uptimeNanoseconds &- prev.uptimeNanoseconds) / 1_000_000_000.0
            if dt > 0.05 {
                let packetsDelta = packetsTotal &- prevAudioPacketsTotal
                let lostDelta = lostTotal &- prevAudioPacketsLostTotal
                let recoveredDelta = recoveredTotal &- prevAudioFecRecoveredTotal
                // Same fold-time model as the video pkts/s: the audio receive
                // totals fold once per ~1s audio-metrics window, which BEATS
                // against this 1Hz tick (0 on some ticks, two windows on
                // others) - divide by the true inter-fold interval instead.
                if packetsDelta > 0, let foldedAt = Self.captureBaselines.audioPacketsCapturedAt {
                    let foldDt =
                        Double(now.uptimeNanoseconds &- foldedAt.uptimeNanoseconds) / 1_000_000_000.0
                    if foldDt > 0.05 { audio.packetsPerSecond = Double(packetsDelta) / foldDt }
                }
                audio.underrunsPerSecond = Double(underrunTotal &- prevAudioUnderrunTotal) / dt
                audio.overrunsPerSecond = Double(overrunTotal &- prevAudioOverrunTotal) / dt
                // Loss rate over expected (accepted + lost); FEC recovery over the
                // packets FEC touched (recovered + accepted). Each gated on a
                // non-zero denominator.
                let expected = packetsDelta &+ lostDelta
                if expected > 0 { audio.lossRate = Double(lostDelta) / Double(expected) }
                let fecBase = recoveredDelta &+ packetsDelta
                if fecBase > 0 { audio.fecRecoveryRate = Double(recoveredDelta) / Double(fecBase) }
            }
        }
        // Fold-time baseline for audio pkts/s - stamped when the totals moved
        // (or on the first tick), mirroring the video baseline in `fillRates`.
        if packetsTotal != prevAudioPacketsTotal || Self.captureBaselines.audioPacketsCapturedAt == nil {
            Self.captureBaselines.audioPacketsCapturedAt = now
        }
        prevAudioPacketsTotal = packetsTotal
        prevAudioPacketsLostTotal = lostTotal
        prevAudioFecRecoveredTotal = recoveredTotal
        prevAudioUnderrunTotal = underrunTotal
        prevAudioOverrunTotal = overrunTotal

        // Published playout state (buffer fill + audio clock drift + re-prime count)
        // + the one-shot cold-start metric. The state is the always-live gauge
        // value `capture()` read once for this tick.
        if let state {
            audio.bufferFillMs = state.bufferFillMs
            audio.audioClockDriftMs = state.audioClockDriftMs
            audio.rePrimeTotal = state.rePrimeTotal
            audio.resamplerPpm = state.resamplerPpm
            audio.engineRunning = state.engineRunning
        }
        // Windowed MIN buffer-fill: pulled (and reset) directly off its own
        // reset-on-read window so each tick's min covers only that window's troughs
        // - the field that proves the cushion holds above 0 (or quantifies a residual
        // drain). Independent of the last-writer-wins state gauge above.
        audio.bufferFillMinMs = counters.takeAudioBufferFillMinMs()
        audio.firstPacketMs = counters.audioFirstPacketMs

        // Only attach the audio block once audio has actually flowed (any total or
        // the first-packet metric is set), so a video-only / pre-audio tick doesn't
        // emit an all-zero audio series.
        if packetsTotal > 0 || audio.firstPacketMs != nil
            || audio.bufferFillMs != nil || audio.bufferFillMinMs != nil {
            snap.audio = audio
        }
    }

    /// Fill the P2 SESSION-LIFECYCLE block (handshake breakdown + reconnect /
    /// disconnect reason + IDR round-trip + corruption), and emit the one-shot
    /// handshake EVENT line. On the exporter queue - never a hot path. The
    /// corruption per-second rate uses the same delta-over-interval model as the
    /// other event rates.
    func fillSessionLifecycle(into snap: inout TelemetrySnapshot, now: DispatchTime) {
        let p2 = counters.p2
        // Handshake breakdown - carried on every tick once any stage has fired so a
        // scrape always sees the latest legs (and the session report reads it too).
        let handshake = p2.handshakeBreakdown()
        if handshake.rtspMs != nil || handshake.enetConnectMs != nil
            || handshake.firstFrameMs != nil || handshake.totalMs != nil {
            snap.handshake = handshake
        }
        // One-shot handshake EVENT line: write it exactly once, the first tick the
        // timeline is COMPLETE (first decoded frame landed), so a reader greps one
        // line for the whole cold-open breakdown instead of scrubbing samples.
        if handshake.complete, !handshakeEventWritten {
            handshakeEventWritten = true
            appendNDJSON(renderHandshakeEvent(handshake))
        }

        snap.reconnectTotal = counters.reconnectTotal.value
        snap.wakeTotal = counters.wakeTotal.value
        snap.routeChangeTotal = counters.routeChangeTotal.value
        // Input backpressure-skip totals (monotonic), split by signal.
        snap.inputFlushSendBackloggedSkipTotal = counters.inputFlushSendBackloggedSkipTotal.value
        snap.inputFlushReliableBackloggedSkipTotal = counters.inputFlushReliableBackloggedSkipTotal.value
        snap.disconnectReason = p2.disconnectReason
        // Process-global per-reason totals (survive session resets) - the durable
        // record the per-session ordinal can't carry past the <1ms exporter teardown.
        snap.disconnectByReason = counters.disconnectByReason.snapshot()

        // IDR/RFI round-trip counts + last measured RTT (the distribution rides the
        // latency histogram). Only attached once at least one request was armed.
        let idrRequests = counters.idrRoundTripRequestTotal.value
        if idrRequests > 0 || counters.idrRoundTripMatchedTotal.value > 0 {
            snap.idrRoundTrip = IdrRoundTripSnapshot(
                requestsTotal: idrRequests,
                matchedTotal: counters.idrRoundTripMatchedTotal.value,
                lastRoundTripMs: p2.lastIdrRoundTripMs)
        }

        // Corruption heuristic total + per-second rate.
        let corruptionTotal = counters.corruptionHeuristicTotal.value
        snap.corruptionTotal = corruptionTotal
        if let prev = prevCaptureTime {
            let dt = Double(now.uptimeNanoseconds &- prev.uptimeNanoseconds) / 1_000_000_000.0
            if dt > 0.05 {
                snap.corruptionPerSecond = Double(corruptionTotal &- prevCorruptionTotal) / dt
            }
        }
        prevCorruptionTotal = corruptionTotal
    }

    /// One-shot CONFIG/DIAL breadcrumb EVENT (`event:"config"`), written as the
    /// FIRST line of every session NDJSON so sessions are self-describing: the
    /// live values of the dials that have to be known to read the data - ping
    /// cadence (the 75ms-keepalive misread happened precisely because the
    /// cadence lived only in a code comment), the audio cushion targets, and
    /// the input idle-gap. Extend this list whenever a new experiment dial
    /// ships; the cost is one row per session. On `workQueue` (from `start()`).
    func writeConfigEvent() {
        let fields: [String] = [
            "\"ts\":\"\(isoFormatter.string(from: Date()))\"",
            "\"session\":\"\(sessionId)\"",
            "\"event\":\"config\"",
            "\"build_commit\":\"\(TelemetryRenderer.jsonStringEscape(BuildInfo.commit))\"",
            // The keepalive is CONDITIONAL (EnvSignalController): both cadence
            // dials + the policy flag, so the session file self-describes the
            // regimes it could run; the live per-row value is
            // keepalive_interval_ms.
            "\"keepalive_fast_ping_ms\":\(Int(UdpPinger.steadyPingIntervalSeconds * 1000))",
            "\"keepalive_relaxed_ping_ms\":\(Int(UdpPinger.relaxedPingIntervalSeconds * 1000))",
            "\"keepalive_conditional\":true",
            // The keepalive's OWN input-idle gate (1.0s radio constant) - NOT
            // the 2s telemetry idle-gap exported below as input_idle_gap_s.
            // Exporting only the 2s key once cost a full false-positive analysis
            // round-trip (a data-only judge misread hundreds of ticks as
            // keepalive violations); these two keys make the NDJSON
            // self-describe the real decision table.
            "\"keepalive_idle_gap_s\":"
                + TelemetryRenderer.jsonNumber(EnvSignalController.keepaliveIdleSeconds),
            // Caution/distress force the fast cadence regardless of input -
            // the override clause of the same table (EnvSignalController.
            // steadyPingInterval), flagged so fast-while-active windows
            // self-explain.
            "\"keepalive_caution_forces_fast\":true",
            // The env-signal layer ships SHADOW: state machine + exports live,
            // every actuation dark except the keepalive gate above.
            "\"env_shadow_mode\":true",
            "\"audio_cushion_base_ms\":\(Int(AudioDecoder.playoutCushionBaseMs))",
            "\"audio_cushion_step_ms\":\(Int(AudioDecoder.playoutCushionStepMs))",
            "\"audio_cushion_max_ms\":\(Int(AudioDecoder.playoutCushionMaxMs))",
            "\"audio_overrun_ceiling_ms\":\(Int(AudioDecoder.bufferOverrunCeilingMs))",
            "\"input_idle_gap_s\":\(Int(TelemetryCounters.idleGapSeconds))"
        ]
        appendNDJSON("{" + fields.joined(separator: ",") + "}")
    }

    /// Render the one-shot CONNECT-HANDSHAKE breakdown as an explicit NDJSON EVENT
    /// object (`event:"handshake"`), distinct from the per-second sample lines so a
    /// reader/grep finds the cold-open breakdown instantly. Numbers only, nil legs
    /// omitted - same discipline as the rest of the exporter.
    private func renderHandshakeEvent(_ breakdown: HandshakeBreakdown) -> String {
        var fields: [String] = [
            "\"ts\":\"\(isoFormatter.string(from: Date()))\"",
            "\"session\":\"\(sessionId)\"",
            "\"event\":\"handshake\""
        ]
        func add(_ key: String, _ value: Double?) {
            guard let value, value.isFinite else { return }
            fields.append("\"\(key)\":\(TelemetryRenderer.jsonNumber(value))")
        }
        add("rtsp_ms", breakdown.rtspMs)
        add("pairing_ms", breakdown.pairingMs)
        add("enet_connect_ms", breakdown.enetConnectMs)
        add("first_frame_ms", breakdown.firstFrameMs)
        add("total_ms", breakdown.totalMs)
        add("click_to_first_frame_ms", breakdown.clickToFirstFrameMs)
        add("launch_path_ms", breakdown.launchPathMs)
        // Launch sub-legs attributing launch_path_ms.
        add("launch_serverinfo_ms", breakdown.launchServerinfoMs)
        add("launch_cancel_ms", breakdown.launchCancelMs)
        add("launch_busy_wait_ms", breakdown.launchBusyWaitMs)
        add("launch_busy_poll_count", breakdown.launchBusyPollCount)
        add("launch_ms", breakdown.launchMs)
        add("launch_build_ms", breakdown.buildMs)
        return "{" + fields.joined(separator: ",") + "}"
    }

    /// Fill the P1 PRESENT/DISPLAY block: read + reset the DISPLAY sampler's
    /// EDR-headroom trend window (min/avg/max) and carry the latest discrete state
    /// (HDR-engaged / screen / ProMotion). On the exporter queue (the sampler runs
    /// its own main-queue timer; this is just the lock-guarded read) - never a hot
    /// path. RESET-ON-READ, so this is the sampler window's only consumer.
    func fillDisplayTelemetry(into snap: inout TelemetrySnapshot) {
        let displaySnap = display.snapshotAndReset()
        snap.edrHeadroomMin = displaySnap.edrHeadroomMin
        snap.edrHeadroomAvg = displaySnap.edrHeadroomAvg
        snap.edrHeadroomMax = displaySnap.edrHeadroomMax
        snap.displayState = displaySnap.state
    }

    /// Fill the P1 RESOURCE block (the P-vs-E-core visibility signal): the
    /// per-thread CPU/QoS/name view + memory footprint + AC/battery (per-process,
    /// `ResourceTelemetry.sample()`), and the SoC P-cluster vs E-cluster active
    /// residency (system, via the `IOReportSampler` delta). Both read on the
    /// exporter's 1Hz queue - never a hot path. The first tick with a per-thread
    /// sample also runs the one-shot QoS AUDIT (logged once) so a hot-path-thread
    /// demotion off the P-core tier surfaces immediately. The cluster residency is
    /// nil on the FIRST tick (the sampler needs two samples to delta) and stays nil
    /// if IOReport isn't available.
    func fillResource(into snap: inout TelemetrySnapshot) {
        let resource = ResourceTelemetry.sample()
        snap.resource = resource
        // One-shot QoS audit on the first tick we have a per-thread sample. Off any
        // hot path (exporter queue); observational only - it changes no scheduling.
        if !qosAuditDone, !resource.threads.isEmpty {
            qosAuditDone = true
            QoSAudit.runAndLog(resource, category: Self.logCategory)
        }
        snap.clusterResidency = ioReport?.sample()
    }

    /// Fill the Track-A diagnostic signals onto the snapshot: host encode-latency
    /// trend + frame size/type (both off the already-captured `stats`), the input
    /// idle→active edge + time-since-last-input, the display-refresh window, and
    /// the thermal/power state. Split out of `capture()` so each stays focused; all
    /// reads happen here on the exporter queue (never the hot path).
    func fillAuxiliarySignals(into snap: inout TelemetrySnapshot, stats: StreamStatsSnapshot) {
        // Host encode-latency trend (min/avg/max) - already collected for the
        // overlay; surfacing it over time makes the host's idle-ramp visible (a
        // big slow encode on the first frame after the scene was static).
        snap.hostEncodeLatencyMinMs = stats.minHostProcessingLatencyMs
        snap.hostEncodeLatencyAvgMs = stats.avgHostProcessingLatencyMs
        snap.hostEncodeLatencyMaxMs = stats.maxHostProcessingLatencyMs

        // Frame size + type - avg/max bytes + %IDR for the big-frame / recurring-
        // IDR hypothesis (a resume that fires a large IDR shows here).
        snap.avgFrameBytes = stats.avgFrameBytes
        snap.maxFrameBytes = stats.maxFrameBytes
        snap.idrFramePercent = stats.idrFramePercent

        // Input idle→active edge + time-since-last-input (the resume-after-idle
        // correlator). Both read off the always-live input gauge - no hot-path
        // cost; the read happens here on the exporter queue.
        snap.inputIdleToActiveTotal = counters.inputIdleToActiveTotal.value
        snap.timeSinceLastInputMs = counters.timeSinceLastInputMs()

        // Display-refresh window (min/avg/max Hz + change marker). RESET-ON-READ,
        // so this is the ONLY caller and it reads exactly once per capture tick.
        if let refresh = source.refreshWindow() {
            snap.refreshMinHz = refresh.minHz
            snap.refreshAvgHz = refresh.avgHz
            snap.refreshMaxHz = refresh.maxHz
            snap.refreshChanged = refresh.changed
        }

        // Thermal + power state - cheap ProcessInfo reads (no allocation, no
        // syscall storm) that catch throttling correlating with a spike. Thermal
        // state is mapped to a 0...3 ordinal (see ProcessMetrics.thermalOrdinal).
        let processInfo = ProcessInfo.processInfo
        snap.thermalState = ProcessMetrics.thermalOrdinal(processInfo.thermalState)
        snap.lowPowerModeEnabled = processInfo.isLowPowerModeEnabled
    }
}
