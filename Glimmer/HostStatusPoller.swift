// Readiness polling holds recent answers through transient network and stream teardown blips.

import AppKit
import Foundation

@MainActor
final class HostPollingState {
    var systemSleeping = false
    var displaysSleeping = false
    var settleUntil = Date.distantPast
    var provenAwake: (hostID: String, at: Date)?
    var establishedHostID: String?
    var movedHostSearch: Task<Void, Never>?
}

extension AppModel {

    /// Restart the selected PC's chip poller: one probe now, then every 10 s while any
    /// of the launcher is on screen (frontmost or not, since the chip shows either way)
    /// and every 20 s otherwise. Only the selected PC is polled.
    func restartHostStatusPolling(
        afterStream: Bool = false,
        sleep: @escaping (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) {
        if afterStream {
            extendPollSettle()
            if let hostID = hostPolling.establishedHostID {
                hostPolling.provenAwake = (hostID, Date())
                hostPolling.establishedHostID = nil
            }
        }
        hostStatusTask?.cancel()
        hostStatusTask = nil

        // Don't poll while a stream is up - the engine has its own RTT
        // metric, and concurrent /serverinfo calls would tag along with the
        // pairing TLS session and confuse Sunshine's logs.
        guard !isStreaming else { return }
        // Both sleep sources must clear before control traffic can resume.
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
            // A selection change cannot publish this PC's answer onto another PC.
            let pollHostID = host.id
            guard await self?.waitForPollSettle(sleep: sleep) == true else { return }
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

    /// Every replacement loop waits out the shared deadline, including activation restarts.
    func waitForPollSettle(
        sleep: (TimeInterval) async throws -> Void = { try await Task.sleep(for: .seconds($0)) }
    ) async -> Bool {
        while hostPolling.settleUntil > Date() {
            do { try await sleep(hostPolling.settleUntil.timeIntervalSinceNow) } catch { return false }
        }
        return !Task.isCancelled && !hostPollingPausedForSleep
    }

    func extendPollSettle(now: Date = Date()) {
        hostPolling.settleUntil = max(hostPolling.settleUntil, now.addingTimeInterval(Self.postStreamPollSettle))
    }

    nonisolated static func holdsGoodStatus(live: HostLiveStatus?, provenAwake: (hostID: String, at: Date)?,
                                            hostID: String, now: Date) -> Bool {
        if HostLiveStatus.isFresh(live, for: hostID, at: now) {
            return true
        }
        guard let provenAwake, provenAwake.hostID == hostID else { return false }
        return now.timeIntervalSince(provenAwake.at) <= HostLiveStatus.stale
    }

    nonisolated static func missPublishesAsleep(streak: Int, holdsGoodStatus: Bool, macHasRoute: Bool) -> Bool {
        macHasRoute && streak >= (holdsGoodStatus ? asleepProbeThreshold : 1)
    }

    /// Hold a recent answer or established stream through transient misses. At cold start,
    /// delaying Asleep without evidence would hide the wake controls behind Checking.
    func publishUnreachable(hostID: String, expectedHostID: String) async {
        guard !Task.isCancelled, !hostPollingPausedForSleep else { return }
        hostUnreachableStreak += 1
        let holds = Self.holdsGoodStatus(live: hostLiveStatus, provenAwake: hostPolling.provenAwake,
                                         hostID: hostID, now: Date())
        guard Self.missPublishesAsleep(streak: hostUnreachableStreak, holdsGoodStatus: holds,
                                      macHasRoute: true) else { return }
        await publishLiveStatus(HostLiveStatus(
            hostID: hostID, state: .asleep, rttMs: nil, sunshineVersion: nil, capturedAt: Date()
        ), expectedHostID: expectedHostID)
    }

    /// One poll: TCP-probe for an RTT, then /serverinfo, published only while `expectedHostID`
    /// is still selected so a late answer can't paint another PC. No route from this Mac is no
    /// verdict: nothing is published, the streak is kept, and `noPath` asks for a quick retry.
    func pollHostStatusOnce(
        for expectedHostID: String, appListFor: Int?,
        probe: @Sendable (String, Int, Int) async -> HostReachability.Outcome = HostReachability.measureRTT,
        macHasRoute: Bool? = nil, publishMiss: ((String, String) async -> Void)? = nil
    ) async -> (appListFor: Int?, noPath: Bool) {
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

        // TCP is the cheapest signal; an unanswered port does not warrant a TLS exchange.
        guard !Task.isCancelled, !hostPollingPausedForSleep else { return (appListFor, false) }
        let probe = await probe(snap.address, snap.info.httpPort, 2_000)
        guard !Task.isCancelled, !hostPollingPausedForSleep else { return (appListFor, false) }

        switch probe {
        case .noPath:
            return (appListFor, true)

        case .unreachable:
            guard macHasRoute ?? (hostRoute.routeClass != .unknown) else { return (appListFor, true) }
            let wasAsleep = hostLiveStatus?.hostID == snap.id && hostLiveStatus?.state == .asleep
            if let publishMiss {
                await publishMiss(snap.id, expectedHostID)
            } else {
                await publishUnreachable(hostID: snap.id, expectedHostID: expectedHostID)
            }
            guard !Task.isCancelled, !hostPollingPausedForSleep else { return (appListFor, false) }
            if !wasAsleep, hostLiveStatus?.hostID == snap.id, hostLiveStatus?.state == .asleep,
               let host = selectedHost, host.id == snap.id {
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
        guard !Task.isCancelled, !hostPollingPausedForSleep else { return }
        hostPolling.movedHostSearch?.cancel()
        hostPolling.movedHostSearch = Task {
            guard !Task.isCancelled, !hostPollingPausedForSleep else { return }
            if await healAddress(of: host, within: 10), !Task.isCancelled { restartHostStatusPolling() }
        }
    }

    /// A late result must not paint another PC after a selection change or sleep.
    func publishLiveStatus(_ status: HostLiveStatus, expectedHostID: String) async {
        await MainActor.run { [weak self] in
            guard let self, !Task.isCancelled, !self.hostPollingPausedForSleep else { return }
            guard let host = self.selectedHost, host.id == expectedHostID else { return }
            self.hostLiveStatus = status
        }
    }
}
