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

    /// Restart the selected PC's chip poller: one probe now, then every 10 s while the
    /// launcher window is open (frontmost or not, since the chip shows either way) and
    /// every 30 s while it's closed. Only the selected PC is polled.
    func restartHostStatusPolling(afterStream: Bool = false) {
        hostStatusTask?.cancel()
        hostStatusTask = nil

        // Don't poll while a stream is up - the engine has its own RTT
        // metric, and concurrent /serverinfo calls would tag along with the
        // pairing TLS session and confuse Sunshine's logs.
        guard !isStreaming else { return }
        // Not across a nap either: the willSleep observer (AppModel+Lifecycle)
        // set this so a poll can't be caught mid-exchange by the Mac going
        // dark; didWake clears it and calls back here.
        guard !hostPollingPausedForSleep else { return }
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
            // Right after a stream, wait out the host's `/cancel` HTTP blip before
            // the first probe so it can't publish a false Asleep. Sleep throws on cancel.
            if afterStream {
                do { try await Task.sleep(for: .seconds(Self.postStreamPollSettle)) } catch { return }
            }
            while !Task.isCancelled {
                await self?.pollHostStatusOnce(for: pollHostID)
                let open = self?.mainWindowVisible == true
                let interval = open ? Self.hostStatusPollSeconds : Self.idleHostStatusPollSeconds
                do { try await Task.sleep(for: .seconds(interval), tolerance: .seconds(2)) } catch { return }
            }
        }
        hostStatusTask = task
    }

    /// Poll interval while the launcher is closed. Only the menu bar panel shows
    /// readiness then, and 30 s (plus tolerance) stays inside `HostLiveStatus.stale`.
    static let idleHostStatusPollSeconds: TimeInterval = 30

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
        let (streak, hasFreshLastGood): (Int, Bool) = await MainActor.run { [weak self] in
            guard let self else { return (0, false) }
            self.hostUnreachableStreak += 1
            // Is there a FRESH last-good status this miss would be protecting?
            // The 3-strike bar exists so a transient blip can't slander a host
            // that was answering moments ago (the post-/cancel window). With
            // nothing published yet (app launch / host switch: the chip is
            // stuck on "Checking..."), that protection protects nothing - it
            // just delays the honest Asleep (and the wake controls behind it)
            // by ~30-40s.
            let live = self.hostLiveStatus
            let fresh = live != nil
                && live?.hostID == hostID
                && live?.state != .unknown
                && Date().timeIntervalSince(live?.capturedAt ?? .distantPast) <= HostLiveStatus.stale
            return (self.hostUnreachableStreak, fresh)
        }
        // Steady state: hold last-good until confirmed unreachable - no flap.
        // Cold start (no fresh last-good): ONE 2s miss publishes Asleep now;
        // if the host was merely blipping, the next probe (≤10s) corrects to
        // Ready - a far cheaper error than 40s of "Checking...".
        guard streak >= (hasFreshLastGood ? Self.asleepProbeThreshold : 1) else { return }
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
                    // MAC backfill (the Luna power gate's Glimmer half): every
                    // successful /serverinfo refreshes the stored MAC - the
                    // only time it's learnable is while the host is online.
                    self.updateHostMac(hostID: expectedHostID, mac: info.macAddress)
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
