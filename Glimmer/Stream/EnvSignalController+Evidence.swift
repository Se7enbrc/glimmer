//
//  EnvSignalController+Evidence.swift
//
//  The EVIDENCE half of the env-signal layer: the ~1Hz capture-tick feed,
//  the ~2s window fold (gap-counter deltas + worst radio/jitter readings),
//  the window classifier and the sustained/hysteresis state machine it
//  advances, the RECONCILE phase that publishes the shared jitter->headroom
//  decision, the session-relative RSSI/tx-rate percentiles, and the
//  per-session reset. Split out of EnvSignalController.swift (pure move) to
//  keep each unit under the length limit; see that file for the full
//  contract, the stored evidence state, and the lock-guarded outputs.
//
//  THREADING is unchanged: everything here runs on the telemetry exporter's
//  serial workQueue (the only `observeCaptureTick` caller, and exactly one
//  exporter exists at a time), so the evidence state stays queue-confined.
//  Only the published outputs - state, stream link, feed freshness, and the
//  reconciler decision - are touched under the controller's `lock`, and the
//  reconciler never calls into its consumers while holding it.
//

import Foundation

extension EnvSignalController {

    // MARK: - Feed (one exporter capture tick)

    /// Fold one ~1Hz capture tick into the evidence layer and publish the
    /// route + freshness for the cadence decision. Exporter workQueue ONLY.
    /// NWPathMonitor participates through `route`: the probe re-probes on
    /// every path change, so a mid-session undock lands here on the next tick.
    func observeCaptureTick(route: StreamRouteSnapshot?, wifi: WiFiSnapshot?) {
        let link = LinkClass(label: route?.linkLabel)
        lock.lock()
        streamLinkValue = link.rawValue  // rawValue ONLY at the publish boundary
        lastFedNanos = DispatchTime.now().uptimeNanoseconds
        lock.unlock()

        // A wired route FORCES CLEAR (the spec's gate), immediately and
        // outside the dwell guard - there is no radio to compensate for, and
        // whatever evidence was mid-run no longer describes the stream path.
        if link == .wired, state != .clear {
            applyTransition(to: .clear, reason: "stream_link_wired")
            resetRuns()
            // Publish REST immediately (don't wait for the window close): a wired
            // route forced CLEAR, so the headroom decision must drop to 0 now -
            // FEC 24ms base + pacer depth 1 = byte-identical to no-reconciler.
            publishRestDecision()
        }

        accumulateRadioBaseline(wifi)
        foldTickIntoWindow(wifi: wifi)
        ticksInWindow += 1
        guard ticksInWindow >= Self.ticksPerWindow else { return }
        evaluateWindow(link: link)
        ticksInWindow = 0
        window = WindowEvidence()
    }

    /// Accumulate the session-relative radio percentile baselines. The radio
    /// is sampled whenever ASSOCIATED (route-independent - the radio is the
    /// same radio while docked); only the EVIDENCE arming is route-gated.
    private func accumulateRadioBaseline(_ wifi: WiFiSnapshot?) {
        guard let wifi, wifi.linkState == .associated else { return }
        if let rssi = wifi.rssiDbm, rssi < 0 {
            rssiHistogram[min(100, -rssi)] += 1
            rssiSampleCount += 1
        }
        if let rate = wifi.txRateMbps, rate > 0 {
            txHistogram[min(240, Int(rate / Self.txBucketMbps))] += 1
            txSampleCount += 1
        }
    }

    /// Fold this tick's gap-counter deltas + radio readings into the current
    /// window. Gap deltas come off the always-live per-socket counters the
    /// receive paths already maintain - no new hot-path cost anywhere. A
    /// non-monotonic step (the connect-edge counter reset of a mid-session
    /// reconnect) re-arms the baseline instead of folding a wrapped delta -
    /// one quiet-looking tick beats a fabricated 2^64-gap "evidence" window.
    private func foldTickIntoWindow(wifi: WiFiSnapshot?) {
        let counters = TelemetryCounters.shared
        let totals = GapTotals(net50: counters.videoGapOver50msTotal.value,
                               audio50: counters.audioGapOver50msTotal.value,
                               net100: counters.videoGapOver100msTotal.value,
                               audio100: counters.audioGapOver100msTotal.value,
                               outOfOrder: counters.videoPacketsOutOfOrderTotal.value,
                               retransmit: counters.enetRetransmitTotal.value)
        if let prev = prevGapTotals,
           totals.net50 >= prev.net50, totals.audio50 >= prev.audio50,
           totals.net100 >= prev.net100, totals.audio100 >= prev.audio100,
           totals.outOfOrder >= prev.outOfOrder, totals.retransmit >= prev.retransmit {
            window.netGap50 &+= totals.net50 &- prev.net50
            window.audioGap50 &+= totals.audio50 &- prev.audio50
            window.netGap100 &+= totals.net100 &- prev.net100
            window.audioGap100 &+= totals.audio100 &- prev.audio100
            window.outOfOrder &+= totals.outOfOrder &- prev.outOfOrder
            window.retransmit &+= totals.retransmit &- prev.retransmit
        }
        prevGapTotals = totals
        // Recv-jitter is a LIVE gauge (last-writer-wins), not a monotonic total -
        // fold the worst (max) reading across the window's ticks, conservative
        // toward detection. Sanitized like the FEC controller does.
        let jitter = counters.recvJitterMs
        if jitter.isFinite, jitter >= 0 { window.maxJitterMs = max(window.maxJitterMs, jitter) }
        if let rssi = wifi?.rssiDbm, rssi < 0 {
            window.rssiDbm = window.rssiDbm.map { min($0, rssi) } ?? rssi
        }
        if let rate = wifi?.txRateMbps, rate > 0 {
            window.txRateMbps = window.txRateMbps.map { min($0, rate) } ?? rate
        }
    }

    /// Close one ~2s window: classify it (degraded / severe / quiet /
    /// neutral), advance the runs, and move the state one step when a run
    /// satisfies the sustained contract. The classification mirrors
    /// FecHeadroomController.observeWindow - escalate thresholds high, relax
    /// thresholds lower, a neutral dead band that resets BOTH runs.
    private func evaluateWindow(link: LinkClass) {
        window.rssiP50 = rssiSessionP50()
        window.txP95 = txRateSessionP95()
        window.radioArmed = link == .wifi && (window.rssiP50 != nil || window.txP95 != nil)

        var radioDegraded = false
        var radioQuiet = true
        if window.radioArmed {
            if let rssi = window.rssiDbm, let p50 = window.rssiP50 {
                radioDegraded = radioDegraded || rssi <= p50 - Self.rssiDegradeDb
                radioQuiet = radioQuiet && rssi > p50 - Self.rssiRelaxDb
            }
            if let rate = window.txRateMbps, let p95 = window.txP95 {
                radioDegraded = radioDegraded || rate <= p95 * Self.txRateDegradeFraction
                radioQuiet = radioQuiet && rate > p95 * Self.txRateRelaxFraction
            }
        }

        // Jitter/loss is now a first-class degradation input
        // alongside co-gap + radio, using FecHeadroomController's already-tuned
        // thresholds (window predicates above). The classifier captures the
        // jitter racer, so the published headroom tracks it instead of two
        // controllers each reading recvJitterMs independently.
        let degraded = window.coGap50 || radioDegraded || window.jitterDegraded
        let severe = window.coGap100 || (window.coGap50 && radioDegraded)
        // Quiet (the relax tier): no >50ms co-gap AND the radio above its
        // relax lines AND jitter/loss below the relax dead band. Single-socket
        // gaps don't block quiet - one path stalling alone is that path's own
        // story, not the link's.
        let quiet = !window.coGap50 && !window.coGap100 && radioQuiet && window.jitterQuiet

        if degraded {
            degradedRun += 1
            runHadCoGap = runHadCoGap || window.coGap50 || window.coGap100
            quietRun = 0
        } else if quiet {
            quietRun += 1
            degradedRun = 0
            runHadCoGap = false
        } else {
            // Neutral: evidence must be CONSECUTIVE to count (the SUSTAINED
            // guarantee), and a not-yet-quiet window can't shorten the dwell.
            degradedRun = 0
            runHadCoGap = false
            quietRun = 0
        }
        severeRun = severe ? severeRun + 1 : 0

        advanceStateMachine(link: link)
        reconcile()
    }

    // MARK: - RECONCILE: publish the shared jitter→headroom decision

    /// Close the window's RECONCILE phase: smooth this window's worst recv-jitter
    /// (EWMA, weight `jitterBaseEwmaWeight` - the FEC controller's), map the
    /// CURRENT link state + smoothed jitter to a desired `headroomLevel`, and
    /// publish both (plus a bumped `generation` on any change) behind `lock` -
    /// the same lock-guarded pattern as `stateValue`/`streamLinkValue`. Both
    /// actuators PULL this on their own ticks; the reconciler never calls into
    /// them and holds only its own lock here.
    ///
    /// The desired level is forced to 0 (REST) whenever the link state is CLEAR
    /// (which a wired route pins), so a clean WIRED link publishes
    /// `headroomLevel == 0` → FEC 24ms base + pacer depth 1 = byte-identical to
    /// no-reconciler. Above CLEAR, the smoothed jitter maps through the same
    /// dead-zone/ladder the FEC soft thresholds use, capped at `maxHeadroomLevel`.
    private func reconcile() {
        // EWMA the worst-jitter of this window (sanitized to the same domain the
        // FEC controller smooths) so a single noisy window can't yank the base.
        let sample = window.maxJitterMs.isFinite ? max(0, window.maxJitterMs) : 0
        reconcileSmoothedJitterMs = reconcileSmoothedJitterMs <= 0
            ? sample
            : reconcileSmoothedJitterMs + Self.jitterBaseEwmaWeight * (sample - reconcileSmoothedJitterMs)

        let desiredLevel = desiredHeadroomLevel(smoothedJitterMs: reconcileSmoothedJitterMs)

        lock.lock()
        let changed = desiredLevel != headroomLevelValue
            || reconcileSmoothedJitterMs != smoothedJitterMsValue
        headroomLevelValue = desiredLevel
        smoothedJitterMsValue = reconcileSmoothedJitterMs
        if changed { decisionGeneration &+= 1 }
        lock.unlock()
    }

    /// Map link state + smoothed jitter to the desired headroom level (REST=0 on
    /// CLEAR/wired). JITTER-ONLY on purpose: the FramePacer reads this as target
    /// DEPTH, so ooo/retransmit drive the FEC reorder axis (which the pacer ignores)
    /// instead - a deeper present buffer adds latency without aiding loss recovery.
    private func desiredHeadroomLevel(smoothedJitterMs: Double) -> Int {
        guard state != .clear else { return 0 }
        let overDeadZone = smoothedJitterMs - Self.headroomJitterDeadZoneMs
        guard overDeadZone > 0 else { return 0 }
        let level = Int((overDeadZone / Self.headroomJitterMsPerLevel).rounded(.up))
        return min(Self.maxHeadroomLevel, max(0, level))
    }

    /// Publish the REST decision (headroom level 0, smoothed jitter 0) and clear
    /// the smoothing accumulator. Called at the wired-forces-CLEAR edge and on a
    /// fresh-session reset so the published decision is at REST the instant the
    /// link is known clean - never a stale escalation an actuator could pull.
    private func publishRestDecision() {
        reconcileSmoothedJitterMs = 0
        lock.lock()
        let changed = headroomLevelValue != 0 || smoothedJitterMsValue != 0
        headroomLevelValue = 0
        smoothedJitterMsValue = 0
        if changed { decisionGeneration &+= 1 }
        lock.unlock()
    }

    /// Apply the run counters to the level - one step at a time, dwell-
    /// guarded, wired pinned to CLEAR (handled at the feed edge).
    private func advanceStateMachine(link: LinkClass) {
        if windowsSinceChange != Int.max { windowsSinceChange += 1 }
        guard link != .wired else { return }
        guard windowsSinceChange >= Self.minDwellWindows else { return }

        let current = state
        // Co-gap runs enter at 3 windows; pure-radio runs need 5 (sustained
        // ~10s - a sag with no delivery impact has to insist).
        let entryWindows = runHadCoGap ? Self.escalateWindows : Self.radioOnlyEscalateWindows
        if current == .clear, degradedRun >= entryWindows {
            applyTransition(to: .caution, reason: runHadCoGap ? "sustained_co_gaps" : "sustained_radio_sag")
            degradedRun = 0
            runHadCoGap = false
            return
        }
        if current == .caution, severeRun >= Self.escalateWindows {
            applyTransition(to: .distress, reason: "sustained_severe_co_gaps")
            severeRun = 0
            return
        }
        if current != .clear, quietRun >= Self.quietWindowsPerStepDown {
            let next = EnvState(rawValue: current.rawValue - 1) ?? .clear
            applyTransition(to: next, reason: "quiet_dwell")
            quietRun = 0
        }
    }

    /// Publish a state change: bump the counter, log the recoverable-state
    /// NOTICE (quiet - never warn/error for a state the machine recovers
    /// from), and emit the `env_state` NDJSON event WITH the evidence vector
    /// so the session is judgeable post-hoc.
    private func applyTransition(to next: EnvState, reason: String) {
        let previous: EnvState
        lock.lock()
        previous = stateValue
        stateValue = next
        lock.unlock()
        guard previous != next else { return }
        windowsSinceChange = 0
        stateChangesTotal.increment()
        Diag.notice("ENV \(previous.label) → \(next.label) (\(reason)) - gates keepalive "
            + "cadence + reconciler headroom", Self.cat)
        var fields = [
            "\"event\":\"env_state\"",
            "\"from\":\"\(previous.label)\"",
            "\"to\":\"\(next.label)\"",
            "\"reason\":\"\(reason)\"",
            "\"stream_link\":\"\(TelemetryRenderer.jsonStringEscape(streamLink))\"",
            "\"win_net_gaps_50\":\(window.netGap50)",
            "\"win_audio_gaps_50\":\(window.audioGap50)",
            "\"win_net_gaps_100\":\(window.netGap100)",
            "\"win_audio_gaps_100\":\(window.audioGap100)",
            "\"radio_armed\":\(window.radioArmed)",
            "\"degraded_run\":\(degradedRun)",
            "\"severe_run\":\(severeRun)",
            "\"quiet_run\":\(quietRun)"
        ]
        if let rssi = window.rssiDbm { fields.append("\"rssi_dbm\":\(rssi)") }
        if let p50 = window.rssiP50 { fields.append("\"rssi_session_p50_dbm\":\(p50)") }
        if let rate = window.txRateMbps {
            fields.append("\"tx_rate_mbps\":\(TelemetryRenderer.jsonNumber(rate))")
        }
        if let p95 = window.txP95 {
            fields.append("\"tx_rate_session_p95_mbps\":\(TelemetryRenderer.jsonNumber(p95))")
        }
        TelemetryExporter.recordEvent(fields)
    }

    // MARK: - Session-relative percentiles

    /// Median RSSI (dBm) from the 1dB histogram; nil until warmed.
    private func rssiSessionP50() -> Int? {
        guard rssiSampleCount >= Self.radioBaselineMinSamples else { return nil }
        let target = (rssiSampleCount + 1) / 2
        var cumulative = 0
        for (index, bucket) in rssiHistogram.enumerated() {
            cumulative += bucket
            if cumulative >= target { return -index }
        }
        return nil
    }

    /// p95 tx-rate (Mbps, bucket midpoint) from the 25Mbps histogram; nil
    /// until warmed.
    private func txRateSessionP95() -> Double? {
        guard txSampleCount >= Self.radioBaselineMinSamples else { return nil }
        let target = Int((Double(txSampleCount) * 0.95).rounded(.up))
        var cumulative = 0
        for (index, bucket) in txHistogram.enumerated() {
            cumulative += bucket
            if cumulative >= target { return (Double(index) + 0.5) * Self.txBucketMbps }
        }
        return nil
    }

    // MARK: - Session lifecycle

    /// Reset for a fresh session: state to CLEAR, baselines/window/runs
    /// emptied, the transition counter zeroed. Called from the exporter's
    /// `start()` on its workQueue (the same confinement as the feed; the
    /// first capture tick is at least a second away, so nothing races it).
    /// No transition event is emitted - a fresh session starting at CLEAR is
    /// a baseline, not a recovery. The ping counters reset at their own
    /// loop-start edges instead (see the counter docs above).
    func resetForNewSession() {
        lock.lock()
        stateValue = .clear
        lock.unlock()
        stateChangesTotal.reset()
        rssiHistogram = [Int](repeating: 0, count: 101)
        rssiSampleCount = 0
        txHistogram = [Int](repeating: 0, count: 241)
        txSampleCount = 0
        prevGapTotals = nil
        ticksInWindow = 0
        window = WindowEvidence()
        resetRuns()
        // Publish REST so a fresh session never starts with a prior session's
        // escalated headroom (the actuators reset their own state at session
        // start too, but the published decision must agree from tick zero).
        publishRestDecision()
    }

    private func resetRuns() {
        degradedRun = 0
        runHadCoGap = false
        severeRun = 0
        quietRun = 0
        windowsSinceChange = Int.max
    }
}
