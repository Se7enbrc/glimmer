//
//  StreamSession+Wake.swift
//
//  WAKE RESILIENCE. Waking the Mac on a different Wi-Fi AP leaves a live stream's
//  connection stale, and the ENet dead-peer envelope measures silence from the
//  monotonic service clock - which PAUSES during sleep - so post-wake a fresh
//  ~10s of AWAKE silence would have to elapse before recovery even starts (a
//  ~10-12s black hang). We hook NSWorkspace wake: re-anchor the silence baseline
//  to NOW, solicit a fresh ACK, and run a BOUNDED liveness probe. If the peer is
//  silent within the budget we drive the EXISTING silent-reconnect episode
//  immediately via `handleHostTerminate(deadPeerTerminationCode)` instead of
//  waiting out the 10s envelope. We do NOT shorten that envelope (it protects
//  recoverable blips) and we do NOT write a new reconnect/teardown - everything
//  routes through the proven path, whose isStreaming/!stopInProgress/!isReconnecting
//  guards collapse a concurrent real dead-peer terminate + this wake terminate
//  into one episode.
//

import Foundation
import AppKit

extension StreamSession {

    /// Arm the sleep/wake observers for the LIVE session. Called once the stream
    /// is up (StreamSession+Start). On NSWorkspace's OWN notification center, not
    /// the default - sleep/wake live there. Removed in `stop()`.
    func armWakeObservers() {
        let wsnc = NSWorkspace.shared.notificationCenter
        wakeObservers.append(wsnc.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.handleSystemWake() }
        })
        wakeObservers.append(wsnc.addObserver(
            forName: NSWorkspace.willSleepNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { await self.handleSystemWillSleep() }
        })
    }

    /// Remove the sleep/wake observers and cancel any in-flight probe. Called from
    /// `stop()`; idempotent (a second call sees an empty list / nil task).
    func teardownWakeObservers() {
        let wsnc = NSWorkspace.shared.notificationCenter
        for token in wakeObservers { wsnc.removeObserver(token) }
        wakeObservers.removeAll()
        wakeProbeTask?.cancel()
        wakeProbeTask = nil
    }

    /// On willSleep, stamp the session wake-suspect so a disconnect that surfaces
    /// across the nap with no more specific cause is attributed to system sleep
    /// (the latch keeps the FIRST concrete reason, so a host terminate still wins).
    func handleSystemWillSleep() async {
        guard isStreaming, !stopInProgress else { return }
        noteTelemetryDisconnect(.systemSleep)
    }

    /// On wake: if the session is live and idle of any teardown/episode, count the
    /// wake, re-anchor the silence clock + solicit a ping, and start the bounded
    /// liveness probe. Everything downstream routes through `handleHostTerminate`.
    func handleSystemWake() async {
        guard isStreaming, reachedLiveState, !stopInProgress, !isReconnecting else { return }
        TelemetryCounters.shared.wakeTotal.increment()
        Diag.notice("Woke from sleep mid-stream - re-anchoring the dead-peer clock "
            + "and probing the link (it may be stale on a new AP).", "Stream")

        // (a)+(b) Solicit a fresh ACK AND re-anchor the dead-peer silence baseline
        // to NOW (the clock paused during sleep). One backend call into the live
        // control channel.
        backend.wakeReanchorAndPing()

        // (c) Bounded liveness probe: budget = max(750ms, N·RTT). If the peer is
        // still silent after the budget, drive the existing reconnect episode now.
        startWakeProbe()
    }

    /// Start (replacing any prior) the bounded probe Task. After the RTT-relative
    /// budget it hops to the actor and checks ENet liveness once: if the peer has
    /// NOT ACKed since the wake re-anchor (silence ≥ budget), it self-terminates
    /// through the EXISTING dead-peer path. The guards in `handleHostTerminate`
    /// make a concurrent real terminate + this one collapse to a single episode.
    private func startWakeProbe() {
        wakeProbeTask?.cancel()
        let rtt = backend.estimatedRtt()?.rttMs ?? Double(Self.wakeProbeFloorMs)
        let budgetMs = min(Self.wakeProbeCeilingMs,
                           max(Self.wakeProbeFloorMs,
                               UInt64(Double(Self.wakeProbeRttMultiple) * rtt)))
        wakeProbeTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: budgetMs * 1_000_000)
            guard !Task.isCancelled, let self else { return }
            await self.finishWakeProbe(budgetMs: budgetMs)
        }
    }

    /// Probe verdict: if the link is still silent past the budget (no fresh ACK
    /// since the wake re-anchor), the post-wake pipe is stale - terminate through
    /// the existing reconnect path. Re-check the lifecycle flags first (an episode
    /// may already be running, in which case `handleHostTerminate` no-ops anyway).
    private func finishWakeProbe(budgetMs: UInt64) async {
        wakeProbeTask = nil
        guard isStreaming, reachedLiveState, !stopInProgress, !isReconnecting else { return }
        // sinceLastAck is measured from the wake re-anchor (handleSystemWake reset
        // it to NOW), so silence ≥ budget means the peer never answered the probe.
        // nil health = the backend can't even report ENet liveness post-wake; treat
        // that as a stale link too (reconnect is recoverable) rather than silently
        // giving up the probe.
        guard let health = backend.enetHealth() else {
            await handleHostTerminate(code: Self.deadPeerTerminationCode)
            return
        }
        if UInt64(health.sinceLastAckMs) >= budgetMs {
            Diag.notice("Wake probe: no ACK in \(health.sinceLastAckMs)ms (budget "
                + "\(budgetMs)ms) - link is stale, reconnecting in place.", "Stream")
            await handleHostTerminate(code: Self.deadPeerTerminationCode)
        }
    }
}
