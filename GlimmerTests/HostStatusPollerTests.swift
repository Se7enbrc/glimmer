// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Readiness and status checks use a fake Sunshine without opening a socket.

import GlimmerEngine
import Foundation
import Testing
@testable import Glimmer

@MainActor
struct HostStatusPollerTests {
    private let settings = IsolatedDefaults()

    init() {}

    private let hostID = "poll-\(UUID().uuidString)"

    private func model(apps: [LibraryApp] = []) -> AppModel {
        let model = AppModel(defaults: settings.defaults)
        model.hostsDefaults = settings.defaults
        model.selectedHost = Glimmer.Host(id: hostID, name: "Tower", customName: nil, localAddress: "192.0.2.10",
                                          manualAddress: nil, apps: apps, lastConnected: nil, serverCertPEM: nil,
                                          appVersion: nil, macAddress: nil)
        model.hostStatusTask?.cancel()
        model.cancelHostReadiness()
        return model
    }

    private func poll(_ model: AppModel, _ sunshine: FakeSunshine, appListFor: Int? = 0,
                      pin: String? = nil) async -> (appListFor: Int?, noPath: Bool) {
        await model.pollHostStatusOnce(
            for: hostID, appListFor: appListFor, probe: { _, _, _ in .reachable(rttMs: 7) },
            makeClient: { info in
                var server = info
                server.serverCertPEM = pin ?? info.serverCertPEM
                return sunshine.client(server)
            })
    }

    @Test func anIdlePCIsReadyWithItsVersionAndRtt() async {
        let model = model()
        model.hostUnreachableStreak = 2
        model.wakeFailedHostID = hostID
        model.wakeFailureReason = .noAnswer
        let sunshine = FakeSunshine { _ in
            FakeSunshine.xml("<appversion>7.1.431.-1</appversion><currentgame>0</currentgame>")
        }
        let result = await poll(model, sunshine)

        #expect(result.appListFor == 0 && !result.noPath)
        #expect(model.hostLiveStatus?.state == .idle)
        #expect(model.hostLiveStatus?.rttMs == 7 && model.hostLiveStatus?.sunshineVersion == "7.1.431.-1")
        #expect(model.hostUnreachableStreak == 0 && model.wakeFailedHostID == nil && model.wakeFailureReason == nil)
        #expect(sunshine.requests.map(\.path) == ["/serverinfo"])
        #expect(sunshine.requests.first?.port == 47989)
    }

    @Test func aRunningAppIsNamedFromTheLibraryOrByItsId() async {
        let named = model(apps: [LibraryApp(id: 42, name: "Portal 2", hdr: false, hidden: false)])
        _ = await poll(named, FakeSunshine { _ in FakeSunshine.xml("<currentgame>42</currentgame>") })
        #expect(named.hostLiveStatus?.state == .streamingApp(name: "Portal 2"))

        let unknown = model()
        let result = await poll(unknown, FakeSunshine { _ in FakeSunshine.xml("<currentgame>77</currentgame>") },
                                appListFor: 77)
        #expect(unknown.hostLiveStatus?.state == .streamingUnknownApp(id: 77))
        #expect(result.appListFor == 77)
    }

    @Test func aChangedCertificateShowsTrustNeededNotAsleep() async {
        let model = model()
        let sunshine = FakeSunshine { _ in throw StreamError.hostUnreachable("pinned host cert mismatch") }
        _ = await poll(model, sunshine, pin: "old-pin")
        #expect(model.hostLiveStatus?.state == .certMismatch)
        #expect(model.hostLiveStatus?.rttMs == 7)
        #expect(sunshine.requests.map(\.tls) == [true])
    }

    @Test func aFailedReplyFromAnAnsweringPCStillShowsReady() async {
        let refused = model()
        _ = await poll(refused, FakeSunshine { _ in FakeSunshine.xml("", status: 503) })
        #expect(refused.hostLiveStatus?.state == .idle)

        let broken = model()
        _ = await poll(broken, FakeSunshine { _ in throw URLError(.networkConnectionLost) })
        #expect(broken.hostLiveStatus?.state == .idle && broken.hostLiveStatus?.rttMs == 7)
    }

    @Test func noRouteOrNoAnswerNeverAsksSunshine() async {
        let model = model()
        let sunshine = FakeSunshine { _ in FakeSunshine.xml("") }
        let noPath = await model.pollHostStatusOnce(for: hostID, appListFor: 3, probe: { _, _, _ in .noPath },
                                                    makeClient: { sunshine.client($0) })
        #expect(noPath.appListFor == 3 && noPath.noPath)

        let offline = await model.pollHostStatusOnce(for: hostID, appListFor: 3, probe: { _, _, _ in .unreachable },
                                                     makeClient: { sunshine.client($0) }, macHasRoute: false)
        #expect(offline.noPath)

        var missed: (String, String)?
        let miss = await model.pollHostStatusOnce(for: hostID, appListFor: 3, probe: { _, _, _ in .unreachable },
                                                  makeClient: { sunshine.client($0) }, macHasRoute: true,
                                                  publishMiss: { missed = ($0, $1) })
        #expect(!miss.noPath && missed?.0 == hostID && missed?.1 == hostID)
        #expect(sunshine.requests.isEmpty)
        #expect(model.hostLiveStatus == nil)
    }

    @Test func aPollForAnotherPCPublishesNothing() async {
        let model = model()
        let sunshine = FakeSunshine { _ in FakeSunshine.xml("") }
        let result = await model.pollHostStatusOnce(for: "den", appListFor: 5, probe: { _, _, _ in .reachable(rttMs: 1) },
                                                    makeClient: { sunshine.client($0) })
        #expect(result.appListFor == 5 && !result.noPath)
        #expect(sunshine.requests.isEmpty && model.hostLiveStatus == nil)
    }

    @Test func readinessWaitsForBothIdleSignalsAndStopsAtTheFirstIdleReply() async {
        let sunshine = FakeSunshine.scripted(["serverinfo": [
            SessionFlow.serverInfo(state: "SUNSHINE_SERVER_BUSY", game: 0),
            SessionFlow.serverInfo(state: "SUNSHINE_SERVER_FREE", game: 7), SessionFlow.idle
        ]])
        let client = sunshine.client(SessionFlow.pairedPC())
        var waits: [TimeInterval] = []
        var busyCount = 0
        let answer = await AppModel.pollReadiness(
            until: Date().addingTimeInterval(5),
            fetch: { try await client.fetchServerInfo(diagnosePinnedFailure: false) },
            busy: { busyCount += 1 }, sleep: { waits.append($0) })
        #expect(answer.map(AppModel.isReadyForStream) == true)
        #expect(sunshine.paths == ["serverinfo", "serverinfo", "serverinfo"])
        #expect(waits == [0.5, 0.5] && busyCount == 2)
        await client.shutdown()
    }

    @Test func readinessTimeoutAndFailedRepliesReleaseTheWait() async {
        let sunshine = FakeSunshine.scripted(["serverinfo": [
            .failure(.hostUnreachable("unavailable")), SessionFlow.running(7)
        ]])
        let client = sunshine.client(SessionFlow.pairedPC())
        var now = Date()
        let deadline = now.addingTimeInterval(1)
        let answer = await AppModel.pollReadiness(
            until: deadline, fetch: { try await client.fetchServerInfo(diagnosePinnedFailure: false) },
            now: { now }, sleep: { now = now.addingTimeInterval($0) })
        #expect(answer?.currentGameID == 7)
        #expect(sunshine.paths == ["serverinfo", "serverinfo"])
        await client.shutdown()
    }

    @Test func busyWithoutAnAppStillBlocksReadiness() async {
        let model = model()
        let sunshine = FakeSunshine { _ in
            FakeSunshine.xml("<currentgame>0</currentgame><state>SUNSHINE_SERVER_BUSY</state>")
        }
        _ = await poll(model, sunshine)
        #expect(model.hostLiveStatus?.state == .streamingUnknownApp(id: 0))
    }

    @Test func cancelledReadinessMakesNoRequests() async {
        let sunshine = FakeSunshine { _ in try SessionFlow.idle.get() }
        let client = sunshine.client(SessionFlow.pairedPC())
        let task = Task { @MainActor in
            await AppModel.pollReadiness(until: Date().addingTimeInterval(5),
                                         fetch: { try await client.fetchServerInfo(diagnosePinnedFailure: false) })
        }
        task.cancel()
        #expect(await task.value == nil)
        #expect(sunshine.requests.isEmpty)
        await client.shutdown()
    }

    @Test func stoppingDuringReadinessCannotStartTheSessionAfterward() async {
        let model = model()
        let gate = AsyncStream<Void>.makeStream()
        let readiness = Task { for await _ in gate.stream {} }
        let launch = Task { try await model.waitForStreamReadiness(readiness) }
        model.menuStopInProgress = true
        gate.continuation.finish()
        await #expect(throws: CancellationError.self) { try await launch.value }
        #expect(model.nativeSession == nil)
    }

    @Test func readinessReasonIsSharedAndScopedToThePC() async throws {
        let model = model()
        let host = try #require(model.selectedHost)
        let sunshine = FakeSunshine.scripted(["serverinfo": [SessionFlow.idle]])
        model.makeNetwork = { sunshine.client($0) }
        model.hostUnreachableStreak = 2
        model.beginHostReadiness(for: host, afterStream: true)
        let task = try #require(model.hostPolling.readinessTasks[host.id])
        model.beginHostReadiness(for: host)
        #expect(model.hostPolling.readinessTasks[host.id] == task)
        #expect(model.polledChip(for: host).fullLabel == "Finishing the last stream…")
        #expect(model.polledChip(for: host).accessibility == "Finishing the last stream…")
        let other = Glimmer.Host(id: "other", name: "Other PC", customName: nil, localAddress: "192.0.2.20",
                             manualAddress: nil, apps: [], lastConnected: nil, serverCertPEM: nil,
                             appVersion: nil, macAddress: nil)
        #expect(model.readinessReason(for: other) == nil)
        await task.value
        #expect(model.selectedReadinessReason == nil)
        #expect(model.hostPolling.readinessTasks.isEmpty)
        #expect(model.hostUnreachableStreak == 0)
        #expect(sunshine.paths == ["serverinfo"])
        #expect(model.hostLiveStatus?.state == .idle)
    }

    @Test(arguments: [1.0, 20, 48, 60, 61, 120, 600])
    func focusUsesRecentEvidenceEvenWhenBackgroundTicksAreDelayed(age: TimeInterval) throws {
        let model = model()
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let host = try #require(model.selectedHost)
        let live = HostLiveStatus(hostID: hostID, state: .idle, rttMs: 7,
                                  capturedAt: now.addingTimeInterval(-age))
        model.hostLiveStatus = live
        model.restartHostStatusPolling(now: now)
        defer {
            model.hostStatusTask?.cancel()
            model.cancelHostReadiness()
        }
        #expect(model.hostStatusTask != nil)
        #expect(model.hostLiveStatus == live)
        #expect((model.readinessReason(for: host) == nil) == (age <= 60))
        #expect((model.hostPolling.readinessTasks[hostID] == nil) == (age <= 60))
    }

    @Test(arguments: [20.0, 120, 600])
    func hiddenDurationDoesNotDiscardTheLastBackgroundAnswer(hiddenFor: TimeInterval) {
        let model = model()
        let hiddenAt = Date(timeIntervalSince1970: 1_700_000_000)
        let focusAt = hiddenAt.addingTimeInterval(hiddenFor)
        model.hostLiveStatus = HostLiveStatus(hostID: hostID, state: .idle,
                                              capturedAt: focusAt.addingTimeInterval(-20))
        model.restartHostStatusPolling(now: focusAt)
        defer {
            model.hostStatusTask?.cancel()
            model.cancelHostReadiness()
        }
        #expect(model.selectedReadinessReason == nil)
        #expect(model.hostPolling.readinessTasks.isEmpty)
    }

    @Test func hidingKeepsPollingAndRevealingRevalidatesWithoutDisabling() throws {
        let model = model()
        model.hostLiveStatus = HostLiveStatus(hostID: hostID, state: .idle, capturedAt: Date())
        model.restartHostStatusPolling()
        defer {
            model.hostStatusTask?.cancel()
            model.cancelHostReadiness()
        }
        let backgroundPoll = try #require(model.hostStatusTask)
        model.hostPollingVisibilityChanged(onScreen: false)
        #expect(model.hostStatusTask == backgroundPoll && !backgroundPoll.isCancelled)
        model.hostPollingVisibilityChanged(onScreen: true)
        #expect(backgroundPoll.isCancelled && model.hostStatusTask != backgroundPoll)
        #expect(model.selectedReadinessReason == nil)
    }

    @Test(arguments: [HostLiveStatus.State.unknown, .asleep, .certMismatch])
    func negativeEvidenceDoesNotBypassReadiness(state: HostLiveStatus.State) throws {
        let model = model()
        let host = try #require(model.selectedHost)
        model.hostLiveStatus = HostLiveStatus(hostID: hostID, state: state, capturedAt: Date())
        model.beginHostReadiness(for: host)
        defer { model.cancelHostReadiness() }
        #expect(model.selectedReadinessReason != nil)
    }

    @Test func postStreamReadinessStillBlocksWithRecentEvidence() throws {
        let model = model()
        let host = try #require(model.selectedHost)
        model.hostLiveStatus = HostLiveStatus(hostID: hostID, state: .idle, capturedAt: Date())
        model.beginHostReadiness(for: host, afterStream: true)
        defer { model.cancelHostReadiness() }
        #expect(model.selectedReadinessReason == "Finishing the last stream…")
        #expect(model.hostPolling.readinessTasks[hostID] != nil)
    }

    @Test(arguments: [false, true])
    func onlyTeardownWaitsFiveSecondsForABusyPC(waitUntilIdle: Bool) async {
        let sunshine = FakeSunshine.scripted(["serverinfo": [SessionFlow.running(7)]])
        let client = sunshine.client(SessionFlow.pairedPC())
        let started = Date().addingTimeInterval(3_600)
        var now = started
        var waits: [TimeInterval] = []
        let answer = await AppModel.pollReadiness(
            until: started.addingTimeInterval(5), waitUntilIdle: waitUntilIdle,
            fetch: { try await client.fetchServerInfo(diagnosePinnedFailure: false) },
            now: { now }, sleep: { waits.append($0); now = now.addingTimeInterval($0) })
        #expect(answer?.currentGameID == 7)
        #expect(sunshine.paths == Array(repeating: "serverinfo", count: waitUntilIdle ? 10 : 1))
        #expect(waits == Array(repeating: 0.5, count: waitUntilIdle ? 10 : 0))
        #expect(now.timeIntervalSince(started) == (waitUntilIdle ? 5 : 0))
    }

    @Test func focusingRepeatedlyCannotHideAPCThatWentAway() async {
        let model = model()
        let now = Date()
        model.hostLiveStatus = HostLiveStatus(hostID: hostID, state: .idle, capturedAt: now)
        for miss in 1...3 {
            model.restartHostStatusPolling(now: now)
            model.hostStatusTask?.cancel()
            await model.publishUnreachable(hostID: hostID, expectedHostID: hostID, now: now)
            #expect(model.hostUnreachableStreak == miss)
        }
        #expect(model.hostLiveStatus?.state == .asleep)
        #expect(model.selectedReadinessReason == nil)
        model.cancelHostReadiness()
    }

    @Test func expiredEvidenceDoesNotHoldAMissingPC() async {
        let model = model()
        let now = Date()
        model.hostLiveStatus = HostLiveStatus(hostID: hostID, state: .idle,
                                              capturedAt: now.addingTimeInterval(-120))
        await model.publishUnreachable(hostID: hostID, expectedHostID: hostID, now: now)
        #expect(model.hostLiveStatus?.state == .asleep)
    }

    @Test func aClickDuringRecentRevalidationHasNoReadinessWait() async throws {
        let model = model()
        let host = try #require(model.selectedHost)
        model.hostLiveStatus = HostLiveStatus(hostID: hostID, state: .idle, capturedAt: Date())
        model.restartHostStatusPolling()
        model.hostStatusTask?.cancel()
        defer { model.cancelHostReadiness() }
        #expect(model.readinessReason(for: host) == nil)
        #expect(model.hostPolling.readinessTasks[hostID] == nil)
        try await model.waitForStreamReadiness(model.hostPolling.readinessTasks[hostID])
    }

    @Test func aPCGoneDuringRevalidationUsesTheExistingLaunchFailure() async throws {
        let model = model()
        let host = try #require(model.selectedHost)
        model.hostLiveStatus = HostLiveStatus(hostID: hostID, state: .idle, capturedAt: Date())
        model.restartHostStatusPolling()
        model.hostStatusTask?.cancel()
        defer { model.cancelHostReadiness() }
        #expect(model.hostPolling.readinessTasks[hostID] == nil)
        let sunshine = FakeSunshine { _ in throw StreamError.hostUnreachable("connection refused") }
        let session = StreamSession(hostDisposition: .cancelOwnedHostSession, backend: InputRecordingBackend())
        let error = await #expect(throws: StreamError.self) {
            _ = try await session.fetchAndVerifyServerInfo(network: sunshine.client(SessionFlow.pairedPC()),
                                                          pcName: host.displayName)
        }
        let failure = AppModel.connectFailure(for: try #require(error), hostName: host.displayName)
        #expect(failure.message == "Couldn't reach Tower. Make sure it's awake and on the same network.")
        #expect(failure.kind == .unreachable)
        #expect(sunshine.paths.allSatisfy { $0 == "serverinfo" })
        #expect(!sunshine.requests.isEmpty)
    }

    @Test func systemSleepInvalidatesEvidenceAndWakeChecksAgain() {
        let model = model()
        model.hostLiveStatus = HostLiveStatus(hostID: hostID, state: .idle, capturedAt: Date())
        model.hostPolling.provenAwake = (hostID, Date())
        model.setHostPollingSleep(system: true, sleeping: true)
        #expect(model.hostLiveStatus == nil && model.hostPolling.provenAwake == nil)
        #expect(model.hostStatusTask == nil && model.hostPolling.readinessTasks.isEmpty)
        model.setHostPollingSleep(system: true, sleeping: false)
        defer {
            model.hostStatusTask?.cancel()
            model.cancelHostReadiness()
        }
        #expect(model.hostStatusTask != nil)
        #expect(model.selectedReadinessReason != nil)
    }

    @Test func pollRequestsAreBoundedAndDoNotDiagnoseAnAlreadyReachablePC() async {
        let model = model()
        let sunshine = FakeSunshine { _ in throw StreamError.hostUnreachable("TLS handshake timed out") }
        _ = await poll(model, sunshine, pin: "saved-pin")
        #expect(sunshine.requests.count == 1)
        #expect(sunshine.requests.allSatisfy { $0.tls && $0.timeout <= 2 })
        #expect(model.hostLiveStatus?.state == .idle)
    }

    @Test func statusIsReadyBeforeTheAppListReturns() async throws {
        let model = model()
        let host = try #require(model.selectedHost)
        var info = model.nativeServerInfo(for: host)
        info.currentGameID = 7
        let fetched = await model.publishAnswer(info, rttMs: 7, hostID: hostID, appListFor: nil,
                                                refreshApps: { _ in
            #expect(model.hostLiveStatus?.state == .streamingUnknownApp(id: 7))
            #expect(model.selectedReadinessReason == nil)
            return false
        })
        #expect(fetched == nil)
        #expect(model.hostLiveStatus?.rttMs == 7)
    }

    @Test func onlyDecodedVideoProvesThePCsVideoPathAcrossLaunches() throws {
        let model = model()
        let host = try #require(model.selectedHost)
        let suite = "video-history-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        model.hostsDefaults = defaults
        model.handleNativeEvent(.connectionEstablished, host: host)
        #expect(!model.hasReceivedVideo(from: host))
        model.handleNativeEvent(.firstFrame, host: host)
        #expect(model.hasReceivedVideo(from: host))
        model.hostPolling.videoReceivedFrom.removeAll()
        #expect(model.hasReceivedVideo(from: host))
        model.handleNativeEvent(.connectionTerminated(errorCode: -100, error: nil), host: host)
        #expect(model.nativeStreamError == "Tower didn't start sending video. Try again.")
        let other = Glimmer.Host(id: "other", name: "Other PC", customName: nil, localAddress: "192.0.2.20",
                                 manualAddress: nil, apps: [], lastConnected: nil, serverCertPEM: nil,
                                 appVersion: nil, macAddress: nil)
        #expect(!model.hasReceivedVideo(from: other))
    }
}
