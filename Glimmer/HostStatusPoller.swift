//
//  HostStatusPoller.swift
//
//  The readiness chip's background poll: a TCP probe of the selected PC's HTTP
//  port for an RTT, then /serverinfo for idle or busy. Lifecycle edges (a PC
//  change, activation, stream start and end) funnel through restartHostStatusPolling().
//

import AppKit
import Foundation

extension AppModel {

    /// Restart the selected PC's chip poller: one probe now, then every 10 s while any
    /// of the launcher is on screen (frontmost or not, since the chip shows either way)
    /// and every 20 s otherwise. Only the selected PC is polled.
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
        // Pairing and Wake and Connect pause the poll so it can't dial beside their own
        // requests; an activation must not re-arm it. A wake holds only its own PC's poll.
        guard pairingAttempt == nil, wakingHostID != host.id else { return }

        // Fresh poll loop → fresh unreachable streak. A miss accrued against
        // the previous host (or before a stream) must not count toward
        // `asleepProbeThreshold` for this loop.
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
            var appListFor: Int?
            var noPathRetry = Self.noPathRetrySeconds
            while !Task.isCancelled {
                let result = await self?.pollHostStatusOnce(for: pollHostID, appListFor: appListFor)
                    ?? (appListFor: appListFor, noPath: false)
                appListFor = result.appListFor
                let onScreen = self?.mainWindowOnScreen == true
                let interval = onScreen ? Self.hostStatusPollSeconds : Self.idleHostStatusPollSeconds
                let delay = result.noPath ? min(noPathRetry, interval) : interval
                noPathRetry = result.noPath ? min(noPathRetry * 2, interval) : Self.noPathRetrySeconds
                do { try await Task.sleep(for: .seconds(delay), tolerance: .seconds(2)) } catch { return }
            }
        }
        hostStatusTask = task
    }

    /// Poll interval while the launcher is off screen. Two held misses (interval, 2 s
    /// tolerance and 2 s probe each) stay inside `HostLiveStatus.stale`, so the
    /// last good status is still fresh and the third strike decides Asleep.
    static let idleHostStatusPollSeconds: TimeInterval = 20

    /// Retry quickly when this Mac has no route, then back off to the normal
    /// interval so a long offline period does not keep dialing every 2 s.
    static let noPathRetrySeconds: TimeInterval = 2

    /// /applist is fetched on a poll loop's first answer (once per selection or
    /// activation), then only for a running app the list lacks, once per app id,
    /// so an app hidden on this Mac can't cause a fetch every poll.
    nonisolated static func needsAppList(runningID: Int, known: Set<Int>, fetchedFor: Int?) -> Bool {
        guard let fetchedFor else { return true }
        return runningID != 0 && runningID != fetchedFor && !known.contains(runningID)
    }

    /// A missed probe, with hysteresis so a Wi-Fi blip or the post-stream `/cancel` blip
    /// can't flap the chip: below `asleepProbeThreshold` misses in a row it holds a fresh
    /// last good status and publishes nothing. With none to hold, one miss shows Asleep.
    func publishUnreachable(hostID: String, expectedHostID: String) async {
        let (streak, hasFreshLastGood): (Int, Bool) = await MainActor.run { [weak self] in
            guard let self else { return (0, false) }
            self.hostUnreachableStreak += 1
            // The bar protects a fresh last good status from a blip. With none
            // (launch, a PC switch) it would only delay the honest Asleep and the
            // wake controls behind it.
            return (self.hostUnreachableStreak, HostLiveStatus.isFresh(self.hostLiveStatus, for: hostID))
        }
        // A cold start's false Asleep is corrected by the next answered poll,
        // a far cheaper error than a minute of "Checking...".
        guard streak >= (hasFreshLastGood ? Self.asleepProbeThreshold : 1) else { return }
        await publishLiveStatus(HostLiveStatus(
            hostID: hostID,
            state: .asleep,
            rttMs: nil,
            sunshineVersion: nil,
            capturedAt: Date()
        ), expectedHostID: expectedHostID)
    }

    /// One poll: TCP-probe for an RTT, then /serverinfo, published only while `expectedHostID`
    /// is still selected so a late answer can't paint another PC. No route from this Mac is no
    /// verdict: nothing is published, the streak is kept, and `noPath` asks for a quick retry.
    func pollHostStatusOnce(for expectedHostID: String, appListFor: Int?) async -> (appListFor: Int?, noPath: Bool) {
        // Snapshot the host on MainActor so we can hand its address etc.
        // off to the background work without crossing the actor boundary
        // with a non-Sendable type.
        let snapshot: (id: String, address: String, info: ServerInfo)? = await MainActor.run { [weak self] in
            guard let self else { return nil }
            guard let host = self.selectedHost, host.id == expectedHostID else { return nil }
            let info = self.nativeServerInfo(for: host)
            return (host.id, info.address, info)
        }
        guard let snap = snapshot else { return (appListFor, false) }

        // Step 1: TCP probe to host's HTTP port. This is the cheapest signal
        // we have for "is the box answering on the network" - if this fails
        // there's no point in trying /serverinfo (which would tack on TLS +
        // a longer timeout). It also gives us a free RTT for the chip.
        let probe = await HostReachability.measureRTT(
            host: snap.address,
            port: snap.info.httpPort,
            timeoutMs: 2_000
        )

        if Task.isCancelled { return (appListFor, false) }

        switch probe {
        case .noPath:
            return (appListFor, true)

        case .unreachable:
            let wasAsleep = hostLiveStatus?.hostID == snap.id && hostLiveStatus?.state == .asleep
            await publishUnreachable(hostID: snap.id, expectedHostID: expectedHostID)
            if !wasAsleep, hostLiveStatus?.hostID == snap.id, hostLiveStatus?.state == .asleep,
               let host = selectedHost {
                searchForMovedHost(host)
            }
            return (appListFor, false)

        case .reachable(let rttMs):
            let fetchedFor = await pollReachableHost(snap.info, hostID: snap.id, rttMs: rttMs,
                                                     appListFor: appListFor)
            return (fetchedFor, false)
        }
    }

    /// The PC took the TCP probe: /serverinfo decides idle, busy or a changed certificate.
    private func pollReachableHost(_ server: ServerInfo, hostID: String, rttMs: Int, appListFor: Int?) async -> Int? {
        // Host answered → clear the unreachable streak so a later transient
        // miss starts counting from zero again, and any stale wake failure.
        hostUnreachableStreak = 0
        if wakeFailedHostID == hostID {
            wakeFailedHostID = nil
            wakeFailureReason = nil
        }
        // Once TCP answers, ask /serverinfo who the PC is and whether it's busy.
        // A fresh NetworkClient per poll has no persistent connection to reuse.
        let client = NetworkClient(server: server)
        do {
            let info = try await client.fetchServerInfo()
            await client.shutdown()
            if Task.isCancelled { return appListFor }
            return await publishAnswer(info, rttMs: rttMs, hostID: hostID, appListFor: appListFor)
        } catch let err as StreamError {
            await client.shutdown()
            if Task.isCancelled { return appListFor }
            // TLS pin mismatch is its own UX: the chip renders certMismatch
            // as an amber "Trust needed" tap-to-re-pair, not "Asleep" - the
            // host is reachable, only the trust relationship broke.
            let state: HostLiveStatus.State
            if case .hostCertChanged = err {
                state = .certMismatch
            } else {
                // TCP answered, so a transient /serverinfo error still shows
                // Ready instead of penalising a working PC.
                state = .idle
            }
            await publishLiveStatus(HostLiveStatus(
                hostID: hostID,
                state: state,
                rttMs: rttMs,
                sunshineVersion: nil,
                capturedAt: Date()
            ), expectedHostID: hostID)
        } catch {
            await client.shutdown()
            if Task.isCancelled { return appListFor }
            // Same forgiving stance as above for non-StreamError throws
            // (URL session timeouts, DNS races, etc.).
            await publishLiveStatus(HostLiveStatus(
                hostID: hostID,
                state: .idle,
                rttMs: rttMs,
                sunshineVersion: nil,
                capturedAt: Date()
            ), expectedHostID: hostID)
        }
        return appListFor
    }

    /// A /serverinfo answer: backfill the MAC (only learnable while the PC is on),
    /// refresh the app list when `needsAppList` says so, then publish idle or the
    /// running app by name.
    private func publishAnswer(_ info: ServerInfo, rttMs: Int, hostID: String, appListFor: Int?) async -> Int? {
        guard let host = selectedHost, host.id == hostID else { return appListFor }
        updateHostMac(hostID: hostID, mac: info.macAddress)
        var fetchedFor = appListFor
        let running = info.currentGameID
        if Self.needsAppList(runningID: running, known: Set(host.apps.map(\.id)), fetchedFor: appListFor) {
            if await refreshAppList(for: host) { fetchedFor = running }
            if Task.isCancelled { return fetchedFor }
        }
        let name = (selectedHost?.apps ?? host.apps).first { $0.id == running }?.name
        let state: HostLiveStatus.State = running == 0 ? .idle
            : name.map { .streamingApp(name: $0) } ?? .streamingUnknownApp(id: running)
        await publishLiveStatus(HostLiveStatus(
            hostID: hostID,
            state: state,
            rttMs: rttMs,
            sunshineVersion: info.appVersion,
            capturedAt: Date()
        ), expectedHostID: hostID)
        return fetchedFor
    }

    /// The first Asleep for a PC may really be a DHCP move: look for it by mDNS for
    /// 10 s, once, outside the poll loop so a restart can't cut the search short.
    private func searchForMovedHost(_ host: Host) {
        Task {
            if await healAddress(of: host, within: 10) { restartHostStatusPolling() }
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
