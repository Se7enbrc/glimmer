//
//  HostStatusPoller.swift
//
//  Background periodic-polling Task for the host readiness chip. Pings the
//  selected host's HTTP port for an RTT, then if reachable pulls /serverinfo
//  to learn idle-vs-busy. Cancellation hooks live on the manager so lifecycle
//  edges (host change, app activation, stream start/end) funnel through
//  `restartHostStatusPolling()`. Originally inline in `AppModel.swift`.
//

import AppKit
import Foundation

extension AppModel {

    /// Cancel any in-flight chip poller and spin up a fresh one for the
    /// currently selected host. Single source of truth for the chip's
    /// background work - `selectHost`, `bootstrap`, `appDidBecomeActive`,
    /// and the stream-end cleanup all funnel through here.
    ///
    /// The poll loop fires:
    ///   * Once immediately (so the chip transitions from "Ready" → "Ready ·
    ///     12 ms" within ~one RTT of host selection, not 10s later)
    ///   * Then every `hostStatusPollSeconds` while we're not streaming AND a
    ///     host is still selected.
    ///
    /// It is NOT gated on the app being frontmost. Moonlight polls its host
    /// grid continuously while on the launcher regardless of window focus, and
    /// so do we: the chip is just as visible when Glimmer's window sits behind
    /// another app, and the old `NSApp.isActive` gate left it stranded on
    /// "Checking..." the moment the user clicked away (the resign-active handler
    /// cancelled the loop, then the last sample aged past `HostLiveStatus.stale`
    /// and the chip reverted). A TCP probe + one `/serverinfo` every 10s is
    /// negligible chatter - the cost the gate saved was never worth a chip that
    /// lies whenever Glimmer isn't frontmost. We still pause for the two cases
    /// that genuinely warrant it: an active stream (the engine owns RTT) and no
    /// host selected.
    ///
    /// We deliberately don't fan out across multiple hosts - only the
    /// selected one is on screen. Background hosts get a stale chip; no
    /// problem, the moment the user switches to them this method re-fires.
    func restartHostStatusPolling(afterStream: Bool = false) {
        hostStatusTask?.cancel()
        hostStatusTask = nil

        // Don't poll while a stream is up - the engine has its own RTT
        // metric, and concurrent /serverinfo calls would tag along with the
        // pairing TLS session and confuse Sunshine's logs.
        guard !isStreaming else { return }
        guard let host = selectedHost else { return }

        // Fresh poll loop → fresh unreachable streak. A miss accrued against
        // the previous host (or before a stream) must not count toward the
        // two-strikes `.asleep` threshold for this loop.
        hostUnreachableStreak = 0

        let task = Task { [weak self] in
            // Capture the host UUID at task-spawn time. If the user switches
            // PCs mid-poll, the new poll task will inherit the new id; this
            // task's results land into `hostLiveStatus` only if its id still
            // matches `selectedHost` at the moment of publication.
            let pollHostID = host.id
            // Re-armed right after a stream ended: wait out the host's
            // `/cancel`-induced HTTP blip before the FIRST probe so we don't
            // race it and publish a false `.asleep` on a host that was
            // streaming moments ago. Sliced so cancellation (host switch /
            // stream restart) stays responsive.
            if afterStream {
                let settleMs = UInt64(Self.postStreamPollSettle * 1000)
                let sliceMs: UInt64 = 250
                let slices = Int(settleMs / sliceMs)
                for _ in 0..<slices {
                    if Task.isCancelled { return }
                    try? await Task.sleep(nanoseconds: sliceMs * 1_000_000)
                }
            }
            while !Task.isCancelled {
                await self?.pollHostStatusOnce(for: pollHostID)
                // Sleep in small slices so cancellation is responsive - a
                // single 10s sleep would block stream-start by up to that
                // long before the cancel propagates.
                let interval = Self.hostStatusPollSeconds
                let sliceMs: UInt64 = 250
                let slices = Int(interval * 1000) / Int(sliceMs)
                for _ in 0..<slices {
                    if Task.isCancelled { return }
                    try? await Task.sleep(nanoseconds: sliceMs * 1_000_000)
                }
            }
        }
        hostStatusTask = task
    }

    /// Publish the chip state for a TCP-unreachable probe, with hysteresis so a
    /// transient miss can't flap the chip. A single timed-out 2 s probe is NOT
    /// proof of anything - Wi-Fi blips, a momentarily busy host, or the
    /// post-stream `/cancel` HTTP blip drop one probe on a perfectly awake box.
    /// So a sub-threshold miss publishes NOTHING: the chip HOLDS its last-good
    /// status ("Ready · 12 ms") instead of blanking to "Checking...", and the
    /// next poll (~10 s) either refreshes it or accrues another strike. Only
    /// once `asleepProbeThreshold` CONSECUTIVE probes have missed do we assert
    /// `.asleep`. (If polling were to stop entirely, the chip's own
    /// `HostLiveStatus.stale` age-out still falls back to "Checking..." - the
    /// honest "we genuinely don't know anymore" path.)
    func publishUnreachable(hostID: String, expectedHostID: String) async {
        let streak: Int = await MainActor.run { [weak self] in
            guard let self else { return 0 }
            self.hostUnreachableStreak += 1
            return self.hostUnreachableStreak
        }
        // Hold last-good until the host is confirmed unreachable - no flap.
        guard streak >= Self.asleepProbeThreshold else { return }
        await publishLiveStatus(HostLiveStatus(
            hostID: hostID,
            state: .asleep,
            rttMs: nil,
            sunshineVersion: nil,
            capturedAt: Date()
        ), expectedHostID: expectedHostID)
    }

    /// Single poll cycle: TCP-probe the host for an RTT, then if reachable
    /// pull /serverinfo to learn idle-vs-busy. Publishes a `HostLiveStatus`
    /// for the UI to consume - but only if `expectedHostID` still matches
    /// the currently-selected host (the user might've switched PCs while
    /// the network call was in flight; we don't want late results painting
    /// the wrong machine's status onto the chip).
    func pollHostStatusOnce(for expectedHostID: String) async {
        // Snapshot the host on MainActor so we can hand its address etc.
        // off to the background work without crossing the actor boundary
        // with a non-Sendable type.
        let snapshot: (id: String, address: String, info: ServerInfo)? = await MainActor.run { [weak self] in
            guard let self else { return nil }
            guard let host = self.selectedHost, host.id == expectedHostID else { return nil }
            let info = self.nativeServerInfo(for: host)
            return (host.id, info.address, info)
        }
        guard let snap = snapshot else { return }

        // Step 1: TCP probe to host's HTTP port. This is the cheapest signal
        // we have for "is the box answering on the network" - if this fails
        // there's no point in trying /serverinfo (which would tack on TLS +
        // a longer timeout). It also gives us a free RTT for the chip.
        let probe = await HostReachability.measureRTT(
            host: snap.address,
            port: snap.info.httpPort,
            timeoutMs: 2_000
        )

        if Task.isCancelled { return }

        switch probe {
        case .unreachable:
            await publishUnreachable(hostID: snap.id, expectedHostID: expectedHostID)
            return

        case .reachable(let rttMs):
            // Host answered → clear the unreachable streak so a later transient
            // miss starts counting from zero again.
            await MainActor.run { [weak self] in self?.hostUnreachableStreak = 0 }
            // Step 2: now that we know the host is up, ask /serverinfo who
            // it is and whether it's busy. We do this on a fresh
            // NetworkClient per poll - the client is cheap to construct and
            // holds no persistent connection, so there's nothing to reuse.
            let client = NetworkClient(server: snap.info)
            do {
                let info = try await client.fetchServerInfo()
                await client.shutdown()
                if Task.isCancelled { return }

                let appNamesByID: [Int: String] = await MainActor.run { [weak self] in
                    guard let self,
                          let host = self.selectedHost,
                          host.id == expectedHostID else { return [:] }
                    return Dictionary(uniqueKeysWithValues: host.apps.map { ($0.id, $0.name) })
                }

                let state: HostLiveStatus.State
                if info.currentGameID == 0 {
                    state = .idle
                } else if let name = appNamesByID[info.currentGameID] {
                    state = .streamingApp(name: name)
                } else {
                    state = .streamingUnknownApp(id: info.currentGameID)
                }
                await publishLiveStatus(HostLiveStatus(
                    hostID: snap.id,
                    state: state,
                    rttMs: rttMs,
                    sunshineVersion: info.appVersion,
                    capturedAt: Date()
                ), expectedHostID: expectedHostID)
            } catch let err as StreamError {
                await client.shutdown()
                if Task.isCancelled { return }
                // TLS pin mismatch is its own UX: the chip renders certMismatch
                // as an amber "Trust needed" tap-to-re-pair, not "Asleep" - the
                // host is reachable, only the trust relationship broke.
                let state: HostLiveStatus.State
                if case .hostUnreachable(let detail) = err,
                   detail.lowercased().contains("cert") || detail.lowercased().contains("mitm") {
                    state = .certMismatch
                } else {
                    // /serverinfo failed for some other reason (timeout, 5xx)
                    // but TCP succeeded - fall back to "idle with RTT"
                    // rather than penalise a working host for a transient
                    // HTTP hiccup. Spec calls this "treat as Ready".
                    state = .idle
                }
                await publishLiveStatus(HostLiveStatus(
                    hostID: snap.id,
                    state: state,
                    rttMs: rttMs,
                    sunshineVersion: nil,
                    capturedAt: Date()
                ), expectedHostID: expectedHostID)
            } catch {
                await client.shutdown()
                if Task.isCancelled { return }
                // Same forgiving stance as above for non-StreamError throws
                // (URL session timeouts, DNS races, etc.).
                await publishLiveStatus(HostLiveStatus(
                    hostID: snap.id,
                    state: .idle,
                    rttMs: rttMs,
                    sunshineVersion: nil,
                    capturedAt: Date()
                ), expectedHostID: expectedHostID)
            }
        }
    }

    /// Land a poll result onto `hostLiveStatus` only if the user hasn't
    /// already swapped to a different host while we were in flight. Keeps
    /// the readiness chip from briefly flashing PC-A's status onto PC-B's
    /// hero card after a quick picker switch.
    func publishLiveStatus(_ status: HostLiveStatus, expectedHostID: String) async {
        await MainActor.run { [weak self] in
            guard let self else { return }
            guard let host = self.selectedHost, host.id == expectedHostID else { return }
            self.hostLiveStatus = status
        }
    }
}
