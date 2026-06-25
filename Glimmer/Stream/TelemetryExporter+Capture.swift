//
//  TelemetryExporter+Capture.swift
//
//  The 1Hz capture path for the opt-in telemetry exporter: the capture timer, the
//  per-tick snapshot assembly from the live `TelemetrySource` + always-live
//  `TelemetryCounters`, and the P1 receive-quality rate derivation. Split out of
//  TelemetryExporter.swift so that file stays focused on the listener/timer/file
//  lifecycle; see that file for the exporter, gate, and the gate/safety contract.
//  The per-section fills `capture()` drives (audio / session-lifecycle / display /
//  resource / auxiliary signals) live in TelemetryExporter+CaptureSections.swift,
//  and the Extras sidecar + cross-tick rate baselines in
//  TelemetryExporter+CaptureExtras.swift - pure moves so every file stays under
//  the file-length budget.
//
//  EVERYTHING here runs on the exporter's serial `workQueue` (never a hot path):
//  the capture timer is scheduled on it, and the snapshot reads either reuse the
//  StatsCollector's existing lock (one read, no second hot-path lock) or read the
//  always-live counters/gauges the engine batches into off the hot path. When the
//  gate is off (default) this exporter is never built, so none of this runs.
//

import Foundation

extension TelemetryExporter {

    // MARK: - Capture

    func startCaptureTimer() {
        // Fresh cross-tick rate baselines for this session - the same
        // per-session lifetime as the exporter's stored prev*-totals (which
        // reset by being instance state on a fresh exporter). On `workQueue`
        // (called from `start()`), same confinement as the capture below.
        Self.captureBaselines = CaptureBaselines()
        let timer = DispatchSource.makeTimerSource(queue: workQueue)
        // 1s cadence with a generous leeway - telemetry is diagnostic, not
        // realtime, and the leeway lets the OS coalesce the wakeup.
        timer.schedule(deadline: .now() + 1.0, repeating: 1.0, leeway: .milliseconds(100))
        timer.setEventHandler { [weak self] in self?.capture() }
        captureTimer = timer
        timer.resume()
    }

    /// Build one snapshot from the live sources, render both forms, store the
    /// Prometheus body for the HTTP path, and append the NDJSON line. On
    /// `workQueue`.
    private func capture() {
        let now = DispatchTime.now()
        let stats = source.videoStats()
        let rtt = source.estimatedRtt()
        let health = source.enetHealth()
        let pacing = source.pacingLiveness()

        var snap = TelemetrySnapshot()
        snap.sessionId = sessionId
        snap.sinceConnectSeconds =
            Double(now.uptimeNanoseconds &- connectInstant.uptimeNanoseconds) / 1_000_000_000.0
        snap.wallClockISO8601 = isoFormatter.string(from: Date())

        snap.receivedFps = stats.receivedFps
        snap.decodedFps = stats.decodedFps
        snap.renderedFps = stats.renderedFps

        // StatsCollector tracks an EMA of decode wall-clock, not a per-frame
        // histogram. Surface the raw EMA only - the true tail (p95/max) lives in
        // the glimmer_decode_time_p_ms / _idr_ms histograms, not a multiple of it.
        snap.decodeEmaMs = stats.avgDecodeTimeMs

        snap.presentCadenceErrorMs = stats.avgPresentCadenceErrorMs
        // on-time/late split: derive counts from the on-time percent if present.
        if let onTimePct = stats.onTimePresentPercent, let rendered = stats.renderedFps {
            let approxPresents = max(rendered, 0)
            snap.presentOnTimeCount = UInt64((approxPresents * onTimePct / 100.0).rounded())
            snap.presentLateCount = UInt64((approxPresents * (100.0 - onTimePct) / 100.0).rounded())
        }

        fillNetwork(into: &snap, stats: stats, rtt: rtt, health: health)

        // Pacing depth/target track the LIVE pacer, never a stale collector
        // sample: `StatsCollector.lastPacingDepth` keeps its last value after the
        // pacer is disabled (written only on a tick), so reading it first reported
        // a stale ~5 for the rest of a direct-enqueue session. When the pacer is
        // gone (disabled → direct enqueue / passthrough) report 0 (not the stale
        // value); while paced this tracks the live queue (now ~1). Target 0 too.
        snap.pacingQueueDepth = pacing != nil ? pacing?.depth : 0
        snap.pacingAdaptiveTargetDepth = pacing != nil ? pacing?.adaptiveTargetDepth : 0
        snap.inFlightDecodeBacklog = source.inFlightDecodeBacklog()

        snap.dropsDecoder = source.decoderDrops()
        snap.dropsBackpressure = source.backpressureDrops()
        snap.dropsPresentationLate = source.presentationLateDrops()

        fillRates(into: &snap, now: now)
        fillAuxiliarySignals(into: &snap, stats: stats)

        let proc = ProcessMetrics.sample()
        snap.processCpuPercent = proc.cpuPercent
        snap.threadCount = proc.threadCount

        // P1 RESOURCE (P-vs-E-core visibility): the per-thread CPU/QoS view +
        // memory footprint + AC/battery (per-process), and the P-cluster vs
        // E-cluster active residency (system, via IOReport). Both on this 1Hz
        // queue - never a hot path. Includes the one-shot QoS audit (logged once).
        fillResource(into: &snap)

        snap.rfiTotal = counters.rfiTotal.value
        snap.idrRequestedTotal = counters.idrRequestedTotal.value
        snap.backlogOverflowTotal = counters.backlogOverflowTotal.value
        snap.presentStallTotal = counters.presentStallTotal.value
        snap.frameLossTotal = counters.frameLossTotal.value
        snap.unrecoverableFrameTotal = counters.unrecoverableFrameTotal.value
        snap.pacerDisabledTotal = counters.pacerDisabledTotal.value
        snap.bookmarkTotal = counters.bookmarkTotal.value
        snap.decoderRecreateTotal = counters.decoderRecreateTotal.value
        snap.staleFrameRepeatTotal = counters.staleFrameRepeatTotal.value

        // P1 DECODE state (HW-decode + pixel format + bit depth + colorspace) +
        // PRESENT/DISPLAY (EDR trend + HDR/screen/ProMotion). Both read off the
        // already-batched gauges/samplers on this queue - no hot-path cost.
        snap.decodeState = counters.decodeState
        fillDisplayTelemetry(into: &snap)

        // P1 AUDIO (the other stream): receive-quality (loss/FEC), output health
        // (buffer fill / under-run / over-run), A/V sync drift, and the cold-start
        // first-packet time. All read off the always-live audio counters/gauges the
        // audio receive + output path batches into - no hot-path cost; the per-second
        // rates are derived from the totals here on the exporter queue. The playout
        // STATE gauge is read ONCE here and shared with the Extras fill below, so
        // one tick's fill and playout-target fields come from one stamp.
        let audioState = counters.audioState
        fillAudio(into: &snap, now: now, state: audioState)

        // P2 SESSION-LIFECYCLE signals: handshake breakdown, reconnect count +
        // disconnect reason, IDR/RFI round-trip counts + last RTT, and the
        // corruption-heuristic total + per-second rate. All read off the always-live
        // counters / `TelemetryCounters.p2` here on the exporter queue - never a hot
        // path. Also emits the one-shot handshake breakdown EVENT line.
        fillSessionLifecycle(into: &snap, now: now)

        // Per-stage latency histograms: one cumulative snapshot per tick off the
        // tracker's atomic buckets (no hot-path cost - the increments happen at
        // present; this is just a read on the exporter queue). Carries the
        // glass-to-glass + input-to-photon composite stages too.
        snap.latencyHistograms = FrameTimingTracker.shared?.histograms.snapshot()

        // Wi-Fi radio (signal 3): one CoreWLAN read on this queue. Reads the
        // current association only - never a scan - so it cannot disturb the link.
        snap.wifi = wifi.sample()

        // Build attribution (signal 5a): the compile-time git SHA + build date.
        snap.buildCommit = BuildInfo.commit
        snap.buildDate = BuildInfo.date
        // The Sunshine server this session connects to (the `host` label).
        snap.serverName = serverLabel

        // Counters newer than the snapshot type (pacer over-target /
        // suppression+gate / control / audio-trim / rumble / per-socket gaps +
        // the pacer tick/release rates), sampled ONCE here and handed to both
        // renderers as one value.
        var extras = fillExtras(now: now, pacing: pacing, audioState: audioState)

        // ROLLING 60s latency window: fold this tick's cumulative bucket
        // snapshot into the per-session ring and carry the windowed difference
        // for the NDJSON `_60s` percentile fields. The cumulative fields stay
        // (session-lifetime truth; a dashboard rate()s the raw buckets itself) -
        // the pair disambiguates "was bad" vs "is bad", which a cumulative-only
        // view gets wrong.
        if let histograms = snap.latencyHistograms {
            extras.latencyRolling60s = Self.captureBaselines.latencyRolling.advance(with: histograms)
        }

        // ENV-SIGNAL (shadow mode): fold this tick's route/radio/gap evidence
        // into the CLEAR/CAUTION/DISTRESS state machine (transitions Diag-log
        // and emit `env_state` events with their evidence vector; the ONLY
        // live actuation is the conditional keepalive cadence), then carry
        // its state + the pings_sent counters on this row.
        EnvSignalController.shared.observeCaptureTick(route: extras.streamRoute, wifi: snap.wifi)
        fillEnvSignal(into: &extras, now: now)

        // Fold this tick into the running session aggregate (signal 5b) - fps
        // min/avg/max, peak depth, worst windows. Done on `workQueue`, off any
        // hot path. GATE-AWARE: the tick is classified first (gated/
        // bring-up/resume/active, off the same suppression+gate gauges this
        // row already carries) so the scorecard's headline numbers cover
        // ACTIVE seconds only - an AFK decode-gate window (fps-min 0, long worst
        // cadence) and the bring-up era would otherwise pollute the cumulative
        // percentiles. Raw stays under `*_raw`.
        let segment = sessionAggregate.classifyTick(
            atSeconds: snap.sinceConnectSeconds,
            hidden: extras.decodeGated || extras.presentSuppressed)
        sessionAggregate.accumulate(snap, segment: segment)
        // ACTIVE-seconds latency: advance the per-tick delta baseline every
        // tick; only active ticks fold into the headline accumulation.
        if let histograms = snap.latencyHistograms {
            sessionAggregate.foldLatency(histograms, active: segment == .active)
        }
        // Seconds-in-state for the scorecard (the shadow-session judge wants
        // "how long was each state" next to the transition count).
        if let ordinal = extras.envStateOrdinal {
            sessionAggregate.noteEnvState(
                ordinal: ordinal, changesTotal: extras.envStateChangesTotal ?? 0)
        }

        // Advance the shared tick baseline LAST: every per-second section above
        // (video rates, audio rates, lifecycle, extras) derives its dt from the
        // PREVIOUS tick's time, so advancing it mid-capture (inside one section)
        // zeroes the dt every later section sees - exactly the bug that left the
        // audio and corruption per-second rates permanently unemitted.
        prevCaptureTime = now

        latestPrometheus = TelemetryRenderer.prometheus(snap, extras: extras)
        appendNDJSON(TelemetryRenderer.ndjson(snap, extras: extras))
    }

    /// Fill the network block: jitter/RTT, the P1 receive-quality goodput + gap
    /// distribution, and the ENet reliable-stream health + retransmit total. Also
    /// refreshes the live RTT gauge the per-frame glass-to-glass reads at present.
    private func fillNetwork(
        into snap: inout TelemetrySnapshot, stats: StreamStatsSnapshot,
        rtt: (rttMs: Double, varianceMs: Double)?,
        health: (sentReliable: Int, oldestUnackedMs: UInt32, sinceLastAckMs: UInt32)?
    ) {
        snap.recvJitterMs = counters.recvJitterMs
        snap.rttMs = rtt?.rttMs
        snap.rttVarianceMs = rtt?.varianceMs
        // P1 receive-quality: goodput vs negotiated (both already on the same
        // StatsCollector snapshot the overlay reads - one read, no second lock) and
        // the inter-packet-gap distribution gauge the receive path publishes ~2s.
        snap.goodputMbps = stats.measuredBitrateMbps
        snap.negotiatedBitrateMbps = stats.negotiatedBitrateMbps
        if let goodput = stats.measuredBitrateMbps,
           let ceiling = stats.negotiatedBitrateMbps, ceiling > 0 {
            snap.goodputUtilization = goodput / ceiling
        }
        if let gap = counters.packetGap {
            snap.packetGapP50Us = gap.p50Us
            snap.packetGapP95Us = gap.p95Us
            snap.packetGapMaxUs = gap.maxUs
        }
        if let fec = counters.fecHealth {
            snap.fecReorderHoldMs = fec.reorderHoldMs
            snap.fecHeadroomLevel = fec.headroomLevel
            snap.fecLossLevel = fec.lossLevel
            snap.fecPercentage = fec.fecPercentage
            snap.fecParityMargin = fec.parityMargin
        }
        if let awdl = counters.awdlHelper {
            snap.awdlSuppressing = awdl.suppressing
            snap.awdlReSuppressTotal = awdl.reSuppressTotal
        }
        // Refresh the live RTT gauge the per-frame glass-to-glass computation
        // reads at present (~RTT/2 for the transit leg). Done here on the 1Hz
        // queue, never the hot path; the present-side read is the only hot-path
        // touch and only when the latency tracker exists (gate on).
        if let rtt { counters.setRttMs(rtt.rttMs) }
        if let health {
            snap.enetSentReliable = health.sentReliable
            snap.enetOldestUnackedMs = health.oldestUnackedMs
            snap.enetSinceLastAckMs = health.sinceLastAckMs
        }
        // P1: reliable-channel retransmit total (monotonic; the climb that precedes
        // a control-stall, paired with the oldest-unacked trend above).
        snap.enetRetransmitTotal = counters.enetRetransmitTotal.value
        snap.ackSilenceNearMissTotal = counters.ackSilenceNearMissTotal.value
    }

    /// Derive the per-second rates from this tick's monotonic-total deltas: pkts/s,
    /// input events/s + flush/s, the FEC-recovery rate, and the P1 receive-quality
    /// loss / out-of-order / duplicate rates. Updates the previous-tick totals.
    private func fillRates(into snap: inout TelemetrySnapshot, now: DispatchTime) {
        let packetsTotal = counters.videoPacketsTotal.value
        let framesTotal = counters.videoFramesTotal.value
        let fecRecoveredTotal = counters.fecRecoveredFramesTotal.value
        let inputEventsTotal = counters.inputEventsTotal.value
        let inputFlushTotal = counters.inputBatchFlushTotal.value
        let preFecLostTotal = counters.videoPacketsLostPreFecTotal.value
        let outOfOrderTotal = counters.videoPacketsOutOfOrderTotal.value
        let duplicateTotal = counters.videoPacketsDuplicateTotal.value
        let staleRepeatTotal = counters.staleFrameRepeatTotal.value
        if let prev = prevCaptureTime {
            let dt = Double(now.uptimeNanoseconds &- prev.uptimeNanoseconds) / 1_000_000_000.0
            if dt > 0.05 {
                let packetsDelta = packetsTotal &- prevPacketsTotal
                // pkts/s over the time the totals last ADVANCED, not this tick's
                // dt: the receive path folds its totals once per ~2s metrics
                // window while this capture ticks at 1Hz, so delta-over-tick-dt
                // read 2x the true wire rate on fold ticks and 0 between them.
                // Emitted only on a fold tick - absent, not a false 0, between.
                if packetsDelta > 0, let foldedAt = Self.captureBaselines.videoPacketsCapturedAt {
                    let foldDt =
                        Double(now.uptimeNanoseconds &- foldedAt.uptimeNanoseconds) / 1_000_000_000.0
                    if foldDt > 0.05 { snap.packetsPerSecond = Double(packetsDelta) / foldDt }
                }
                snap.inputEventsPerSecond = Double(inputEventsTotal &- prevInputEventsTotal) / dt
                snap.inputFlushPerSecond = Double(inputFlushTotal &- prevInputFlushTotal) / dt
                // P1 PRESENT stale-frame repeats/sec (the invisible-stutter rate).
                snap.staleRepeatsPerSecond = Double(staleRepeatTotal &- prevStaleFrameRepeatTotal) / dt
                let framesDelta = framesTotal &- prevFramesTotal
                if framesDelta > 0 {
                    snap.fecRecoveryRate =
                        Double(fecRecoveredTotal &- prevFecRecoveredTotal) / Double(framesDelta)
                }
                // P1 receive-quality RATES. Loss is lost / (lost + received) ==
                // lost / expected; OOO + dup are over received (the packets we
                // actually got). Computed only when packets flowed this window so a
                // silent tick doesn't emit a 0/0.
                fillReceiveQualityRates(
                    into: &snap, packetsDelta: packetsDelta,
                    preFecLostDelta: preFecLostTotal &- prevPreFecLostTotal,
                    outOfOrderDelta: outOfOrderTotal &- prevOutOfOrderTotal,
                    duplicateDelta: duplicateTotal &- prevDuplicateTotal)
            }
        }
        // Stamp the fold-time baseline whenever the packet totals MOVED (or on
        // the first tick, arming the window): the time recorded here is what the
        // next fold's pkts/s divides by. The shared tick baseline
        // (`prevCaptureTime`) advances once per capture, at the end of
        // `capture()`, after every per-second section has read it.
        if packetsTotal != prevPacketsTotal || Self.captureBaselines.videoPacketsCapturedAt == nil {
            Self.captureBaselines.videoPacketsCapturedAt = now
        }
        prevPacketsTotal = packetsTotal
        prevFramesTotal = framesTotal
        prevFecRecoveredTotal = fecRecoveredTotal
        prevInputEventsTotal = inputEventsTotal
        prevInputFlushTotal = inputFlushTotal
        prevPreFecLostTotal = preFecLostTotal
        prevOutOfOrderTotal = outOfOrderTotal
        prevDuplicateTotal = duplicateTotal
        prevStaleFrameRepeatTotal = staleRepeatTotal
    }

    /// Derive the P1 per-second receive-quality RATES from this tick's monotonic
    /// deltas. Pre-FEC loss is lost / (lost + received) (== lost / expected, since
    /// received + lost == the packets the host actually sent); out-of-order and
    /// duplicate are over the received packets. Each rate is emitted only when its
    /// denominator is non-zero so a silent tick doesn't publish a 0/0. On the
    /// exporter queue - never the hot path.
    private func fillReceiveQualityRates(
        into snap: inout TelemetrySnapshot,
        packetsDelta: UInt64, preFecLostDelta: UInt64,
        outOfOrderDelta: UInt64, duplicateDelta: UInt64
    ) {
        let expected = packetsDelta &+ preFecLostDelta
        if expected > 0 {
            snap.preFecLossRate = Double(preFecLostDelta) / Double(expected)
        }
        if packetsDelta > 0 {
            snap.outOfOrderRate = Double(outOfOrderDelta) / Double(packetsDelta)
            snap.duplicateRate = Double(duplicateDelta) / Double(packetsDelta)
        }
    }
}
