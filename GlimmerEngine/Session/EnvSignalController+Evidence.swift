// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import Synchronization

extension EnvSignalController {

    // MARK: - Feed (one 2 s session tick)

    /// Native sampling stays off the main actor; retired sessions cannot publish late evidence.
    package func observeStreamTick() {
        observationLock.withLock {
            guard let id = observationID else { return }
            let source = observations
            feedQueue.async { [self] in
                guard observationLock.withLock({ observationID == id }) else { return }
                let route = source?.route()
                let wifi = source?.wifi()
                observationLock.withLock {
                    guard observationID == id else { return }
                    observeCaptureTick(route: route, wifi: wifi)
                }
            }
        }
    }

    /// Fold one 2 s tick into the evidence layer and publish the route + freshness for the
    /// cadence decision. `feedQueue` only (tests call it directly). The probe re-probes on
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
            // pacer depth 1 = byte-identical to no-reconciler.
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

    /// Fold existing receive counters without hot-path work. A reconnect counter reset re-arms
    /// the baseline rather than turning unsigned wraparound into fabricated gap evidence.
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
        let datagramUs = VideoReceiveStatus.lastDatagramMicroseconds
        if let prev = prevDatagramUs, datagramUs > prev { window.videoArrived = true }
        prevDatagramUs = datagramUs
        // Recv-jitter is a LIVE gauge (last-writer-wins), not a monotonic total -
        // fold the worst (max) reading across the window's ticks, conservative
        // toward detection, sanitized to a finite non-negative value.
        let jitter = counters.recvJitterMs
        if jitter.isFinite, jitter >= 0 { window.maxJitterMs = max(window.maxJitterMs, jitter) }
        if let rssi = wifi?.rssiDbm, rssi < 0 {
            window.rssiDbm = window.rssiDbm.map { min($0, rssi) } ?? rssi
        }
        if let rate = wifi?.txRateMbps, rate > 0 {
            window.txRateMbps = window.txRateMbps.map { min($0, rate) } ?? rate
        }
    }

    /// Escalation needs sustained evidence; lower relax thresholds and a neutral dead band reset
    /// both runs. Windows without video contain no evidence and leave the state untouched.
    func evaluateWindow(link: LinkClass) {
        guard window.videoArrived else { return }
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

        // Jitter/loss is a first-class degradation input alongside co-gap +
        // radio (the window predicates), so the published headroom tracks it.
        let degraded = window.coGap50 || radioDegraded || window.jitterDegraded
        let severe = window.coGap100 || (window.coGap50 && radioDegraded)
        // Quiet requires no co-gap, recovered radio and low jitter/loss. One socket stalling alone
        // is that path’s evidence and does not block link-wide recovery.
        let quiet = !window.coGap50 && !window.coGap100 && radioQuiet && window.jitterQuiet

        if degraded {
            degradedRun += 1
            runHadCoGap = runHadCoGap || window.coGap50 || window.coGap100
            runHadRadioSag = runHadRadioSag || radioDegraded
            quietRun = 0
        } else if quiet {
            quietRun += 1
            degradedRun = 0
            runHadCoGap = false
            runHadRadioSag = false
        } else {
            // Neutral: evidence must be CONSECUTIVE to count (the SUSTAINED
            // guarantee), and a not-yet-quiet window can't shorten the dwell.
            degradedRun = 0
            runHadCoGap = false
            runHadRadioSag = false
            quietRun = 0
        }
        severeRun = severe ? severeRun + 1 : 0

        advanceStateMachine(link: link)
        reconcile()
    }

    // MARK: - RECONCILE: publish the shared jitter→headroom decision

    /// Publish EWMA jitter and the bounded headroom ladder; consumers pull on existing ticks.
    /// Clear (including every wired route) forces level0, retaining the depth1 baseline.
    /// Generation advances only when the level or smoothed jitter changes.
    private func reconcile() {
        // EWMA the worst-jitter of this window (sanitized to a finite,
        // non-negative value) so a single noisy window can't yank the level.
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
        pacerHeadroom.publish(level: headroomLevelValue, generation: decisionGeneration)
        lock.unlock()
    }

    /// Map link state + smoothed jitter to the desired headroom level (REST=0 on
    /// CLEAR/wired). JITTER-ONLY on purpose: the FramePacer reads this as target
    /// DEPTH, and a deeper present buffer adds latency without aiding loss recovery.
    private func desiredHeadroomLevel(smoothedJitterMs: Double) -> Int {
        guard state != .clear else { return 0 }
        let overDeadZone = smoothedJitterMs - Self.headroomJitterDeadZoneMs
        guard overDeadZone > 0 else { return 0 }
        let level = Int((overDeadZone / Self.headroomJitterMsPerLevel).rounded(.up))
        return min(Self.maxHeadroomLevel, max(0, level))
    }

    /// Reset smoothing and publish level0 at session start or wired recovery, so no actuator
    /// inherits a prior escalation.
    private func publishRestDecision() {
        reconcileSmoothedJitterMs = 0
        lock.lock()
        let changed = headroomLevelValue != 0 || smoothedJitterMsValue != 0
        headroomLevelValue = 0
        smoothedJitterMsValue = 0
        if changed { decisionGeneration &+= 1 }
        pacerHeadroom.publish(level: headroomLevelValue, generation: decisionGeneration)
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
            applyTransition(to: .caution, reason: Self.cautionReason(
                coGap: runHadCoGap, radioSag: runHadRadioSag))
            degradedRun = 0
            runHadCoGap = false
            runHadRadioSag = false
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

    /// The CAUTION entry label, named for the strongest evidence the run held
    /// (jitter/ooo/retransmit is the only other degraded input).
    static func cautionReason(coGap: Bool, radioSag: Bool) -> String {
        if coGap { return "sustained_co_gaps" }
        return radioSag ? "sustained_radio_sag" : "sustained_jitter_retransmit"
    }

    /// Recoverable transitions log at notice and emit the full evidence vector for later judging.
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
        #if os(macOS) || GLIMMER_DIAGNOSTICS
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
        #endif
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

    /// Adopt prepared native observations; reset to CLEAR on the evidence queue before its first tick.
    package func beginSession(observations source: EnvObservationSource? = nil) {
        let previous = observationLock.withLock {
            let previous = observations
            let id = UUID()
            observationID = id
            observations = source
            feedQueue.async { [self] in
                observationLock.withLock {
                    guard observationID == id else { return }
                    resetForNewSession()
                }
            }
            return previous
        }
        previous?.stop()
    }

    /// Reset for a fresh session: state to CLEAR, baselines/window/runs emptied, the transition
    /// counter zeroed. Runs on `feedQueue` ahead of the first tick (`beginSession`). No transition
    /// event: a session starting at CLEAR is a baseline. Ping counters reset at their loop edges.
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
        prevDatagramUs = nil
        ticksInWindow = 0
        window = WindowEvidence()
        resetRuns()
        // Publish REST so a fresh session never starts with a prior session's
        // escalated headroom (the actuators reset their own state at session
        // start too, but the published decision must agree from tick zero).
        publishRestDecision()
    }

    /// Withdraw the decision synchronously; a blocked native sample cannot revive it after stop.
    package func endSession() {
        let source = observationLock.withLock {
            let source = observations
            observations = nil
            observationID = nil
            lock.withLock {
                headroomLevelValue = 0
                smoothedJitterMsValue = 0
                decisionGeneration = 0
                pacerHeadroom.publish(level: 0, generation: 0)
            }
            return source
        }
        source?.stop()
    }

    private func resetRuns() {
        degradedRun = 0
        runHadCoGap = false
        runHadRadioSag = false
        severeRun = 0
        quietRun = 0
        windowsSinceChange = Int.max
    }
}
