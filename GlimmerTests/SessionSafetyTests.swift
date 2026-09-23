import Foundation
import Testing
@testable import Glimmer

struct SessionSafetyTests {
    @Test func hdrSnapshotsNeverMixBlobs() async {
        let store = HDRMetadataStore()
        await withTaskGroup(of: Void.self) { group in
            for value in UInt8(1)...UInt8(4) {
                group.addTask {
                    let metadata = HDRMetadata(mdcv: Data([value]), contentLightLevel: Data([value]))
                    for _ in 0..<1_000 {
                        store.publish(metadata)
                        let snapshot = store.snapshot
                        #expect(snapshot.mdcv == snapshot.contentLightLevel)
                        store.publish(.empty)
                    }
                }
            }
        }
    }

    @Test func hdrMetadataChangesIncludeEitherBlobAndReset() {
        let store = HDRMetadataStore()
        let first = HDRMetadata(mdcv: Data([1]), contentLightLevel: Data([2]))
        store.publish(first)
        #expect(store.snapshot == first)
        store.publish(HDRMetadata(mdcv: first.mdcv, contentLightLevel: Data([3])))
        #expect(store.snapshot != first)
        store.publish(HDRMetadata(mdcv: Data([4]), contentLightLevel: first.contentLightLevel))
        #expect(store.snapshot != first)
        store.publish(.empty)
        #expect(store.snapshot == .empty)
    }

    @Test func abandonedLaunchCannotContinue() {
        for cancelled in [false, true] {
            for streaming in [false, true] {
                for stopping in [false, true] {
                    #expect(StreamAttempt.shouldContinue(
                        cancelled: cancelled, streaming: streaming, stopping: stopping)
                        == (!cancelled && streaming && !stopping))
                }
            }
        }
    }

    @Test func cancellationAfterSuspensionPreventsHostMutation() async {
        let request = SafetyTestGate()
        let entered = SafetyTestGate()
        let mutation = SafetyTestCounter()
        let task = Task {
            await entered.open()
            await request.wait()
            guard StreamAttempt.shouldContinue(
                cancelled: Task.isCancelled, streaming: true, stopping: false) else {
                throw CancellationError()
            }
            await mutation.increment()
        }
        await entered.wait()
        task.cancel()
        await request.open()
        do {
            try await task.value
            Issue.record("Cancelled launch continued")
        } catch {
            #expect(error is CancellationError)
        }
        #expect(await mutation.value == 0)
    }

    @Test func cancelledTransportCannotSendAfterHandshake() throws {
        let lifetime = ControlTransport.RequestLifetime(timeout: 10)
        try lifetime.check()
        lifetime.cancel()
        #expect(throws: CancellationError.self) { try lifetime.check() }
    }

    @Test func quitWaitsForOverlappingStop() async {
        let teardown = SharedTeardown()
        let entered = SafetyTestGate()
        let release = SafetyTestGate()
        let completed = SafetyTestCounter()
        let first = Task {
            await teardown.run {
                await entered.open()
                await release.wait()
                await completed.increment()
            }
        }
        await entered.wait()
        let quit = Task {
            await TerminationGate.runBounded(seconds: 2) {
                await teardown.run { Issue.record("Teardown ran twice") }
            }
        }
        #expect(await completed.value == 0)
        await release.open()
        #expect(await quit.value)
        await first.value
        #expect(await completed.value == 1)
    }

    @Test func quitBoundDoesNotTreatRunningTeardownAsFinished() async {
        let teardown = SharedTeardown()
        let entered = SafetyTestGate()
        let release = SafetyTestGate()
        let first = Task {
            await teardown.run {
                await entered.open()
                await release.wait()
            }
        }
        await entered.wait()
        let finished = await TerminationGate.runBounded(seconds: 0.02) {
            await teardown.run { Issue.record("Teardown ran twice") }
        }
        #expect(!finished)
        await release.open()
        await first.value
    }

    @Test func deadlineBoundsUncooperativeRequestAndPreventsNextLeg() async {
        let release = SafetyTestGate()
        let unwound = SafetyTestGate()
        let entered = SafetyTestGate()
        let mutations = SafetyTestCounter()
        let start = Date()
        do {
            try await StreamAttempt.run(until: start.addingTimeInterval(0.02)) {
                await entered.open()
                await release.wait()
                defer { Task { await unwound.open() } }
                try Task.checkCancellation()
                await mutations.increment()
            }
            Issue.record("Request outlived its deadline")
        } catch {
            #expect(Date().timeIntervalSince(start) < 1)
        }
        await release.open()
        if await entered.isOpen { await unwound.wait() }
        #expect(await mutations.value == 0)
    }

    @Test func expiredDeadlineDoesNotStartAnotherRequest() async {
        let requests = SafetyTestCounter()
        do {
            try await StreamAttempt.run(until: Date().addingTimeInterval(-1)) {
                await requests.increment()
            }
            Issue.record("Expired attempt started")
        } catch {
            #expect(await requests.value == 0)
        }
    }

    @Test func occupiedHostsNeedExplicitAuthorizationUnlessOwned() {
        #expect(StreamAttempt.requiresTakeover(occupied: true, owner: nil, client: "ours", authorized: false))
        #expect(StreamAttempt.requiresTakeover(occupied: true, owner: "other", client: "ours", authorized: false))
        #expect(!StreamAttempt.requiresTakeover(occupied: true, owner: "ours", client: "ours", authorized: false))
        #expect(!StreamAttempt.requiresTakeover(occupied: true, owner: nil, client: "ours", authorized: true))
        #expect(!StreamAttempt.requiresTakeover(occupied: false, owner: nil, client: "ours", authorized: false))
        #expect(StreamAttempt.requiresTakeover(occupied: true, owner: "", client: "", authorized: false))
    }

    /// Each start failure gets copy that names its real fix, and a kind the
    /// banner and menu bar route their action on. Only a PC that never
    /// answered is told to check that it's awake.
    @Test func connectFailuresNameTheFix() {
        // The pinned-path verdicts, named as fetchServerInfo names them.
        let classify = { NetworkClient.classifyPairedPathFailure($0, hostName: "Tower") }
        let stuck = "Tower is awake, but Sunshine's secure port (47984) is refusing connections because "
            + "its HTTPS listener is stuck. Restart Sunshine on the PC; quitting Glimmer will not help."
        let cases: [(Error, AppModel.StreamErrorKind, String)] = [
            (StreamError.hostUnreachable("connect to 192.0.2.10:47984 failed or timed out"), .unreachable,
             AppModel.unreachableMessage("Tower")),
            (classify("connect to 192.0.2.10:47984 failed or timed out"), .other, stuck),
            (classify("pinned host cert mismatch"), .pairing,
             "Tower's certificate changed. To trust it, choose Pair Again… from the PC's ⋯ menu."),
            (classify("Host requires pairing (Not paired)"), .pairing,
             "Tower no longer recognizes this Mac, or this Mac is switched off on Sunshine's Troubleshooting page. "
                + "Choose Pair Again… from the PC's ⋯ menu."),
            (classify("TLS handshake to 192.0.2.10:47984 failed (SSL_connect)"), .pairing,
             "Tower rejected this Mac's certificate. Choose Pair Again… from the PC's ⋯ menu."),
            (NetworkClient.notPaired("Tower"), .pairing,
             "Tower isn't paired with this Mac. Choose Pair Again… from the PC's ⋯ menu."),
            (classify("empty HTTP response"), .other,
             "Tower answers on its plain port but not its secure one. Restart Sunshine on the PC."),
            (StreamError.streamPortsBlocked(proto: "UDP", port: 47999), .other,
             "Tower answered, but the stream couldn't get through. Check that the PC's firewall allows UDP 47999."),
            (StreamError.hostTimedOut, .other, "Tower took too long to start the app."),
            (StreamError.hostRefused(message: "Is a display connected", code: 503), .other,
             "Tower couldn't start the app: Is a display connected."),
            (StreamError.hostRefused(message: "Is a display connected?", code: 503), .other,
             "Tower couldn't start the app: Is a display connected?"),
            (StreamError.launchFailed("Malformed XML on /launch"), .other, "Tower couldn't start the app."),
            (StreamError.sessionFailed(-1), .other, "Tower answered, but the stream couldn't start."),
            (StreamError.truncatedRead("recv timeout"), .unreachable, AppModel.unreachableMessage("Tower"))
        ]
        for (error, kind, message) in cases {
            let failure = AppModel.connectFailure(for: error, hostName: "Tower")
            #expect(failure.kind == kind, "\(error)")
            #expect(failure.message == message)
            #expect(!failure.message.contains(" - ") && !failure.message.contains("192.0.2.10"))
        }
    }

    /// Before /launch no request deadline is set, so a request that runs out
    /// its own clock is a PC that never answered, whichever timer wins. Under
    /// the launch deadline the same timeout means the app was slow to start.
    @Test func unansweredRequestBeforeLaunchIsUnreachable() async {
        func failure(requestDeadline: Date?) async -> (message: String, kind: AppModel.StreamErrorKind)? {
            do {
                try await StreamAttempt.run(until: Date().addingTimeInterval(0.05)) {
                    try await Task.sleep(for: .seconds(5))
                }
                return nil
            } catch {
                let error = NetworkClient.requestError(error, requestDeadline: requestDeadline)
                return AppModel.connectFailure(for: error, hostName: "Tower")
            }
        }
        let beforeLaunch = await failure(requestDeadline: nil)
        #expect(beforeLaunch?.kind == .unreachable)
        let duringLaunch = await failure(requestDeadline: .distantFuture)
        #expect(duringLaunch?.message == "Tower took too long to start the app.")
    }

    /// Cancel, the quit chord and the close button all end a connect by choice:
    /// no banner, no "Stream ended", no last-played stamp. A real failure isn't,
    /// and neither is Cancel Connection during a reconnect of a live stream.
    @Test func userStopsAreNotConnectFailures() {
        #expect(AppModel.connectWasCancelled(by: CancellationError(), cancelRequested: false))
        #expect(AppModel.connectWasCancelled(by: StreamError.sessionFailed(-1), cancelRequested: true))
        #expect(!AppModel.connectWasCancelled(by: nil, cancelRequested: true))
        #expect(!AppModel.connectWasCancelled(by: StreamError.sessionFailed(-1), cancelRequested: false))
        #expect(!AppModel.connectWasCancelled(by: nil, cancelRequested: false))
    }

    /// Only the user's stop turns a failed connect leg into a cancel; a real
    /// failure keeps the engine's cause instead of collapsing to a bare code.
    @Test func connectLegKeepsItsCause() {
        let userStop = StreamSession.connectLegError(StreamError.sessionFailed(-1), stoppedBy: .userStopped)
        #expect(userStop is CancellationError)
        let blocked = StreamSession.connectLegError(
            StreamError.streamPortsBlocked(proto: "UDP", port: 47999), stoppedBy: nil)
        guard case .streamPortsBlocked(let proto, let port) = blocked as? StreamError else {
            Issue.record("expected streamPortsBlocked, got \(blocked)")
            return
        }
        #expect(proto == "UDP" && port == 47999)
        guard case .sessionFailed(-1) = StreamSession.connectLegError(CancellationError(), stoppedBy: nil)
            as? StreamError else {
            Issue.record("an unexplained cancel is still a failed connect")
            return
        }
    }

    /// The PC ending the session during bring-up tears it down too, but that
    /// is a failure the user must hear about, not a silent cancel.
    @Test func hostEndDuringConnectStillShowsABanner() {
        let error = StreamSession.connectLegError(CancellationError(), stoppedBy: .hostError)
        #expect(!(error is CancellationError))
        #expect(!AppModel.connectWasCancelled(by: error, cancelRequested: false))
        #expect(AppModel.connectFailure(for: error, hostName: "Tower").message
            == "Tower answered, but the stream couldn't start.")
    }

    /// An RTSP port that never took the connection names itself; other RTSP
    /// failures keep their code.
    @Test func rtspConnectTimeoutNamesThePort() {
        guard case .streamPortsBlocked("TCP", 48010) = NativeBackend.mapToStreamError(
            RtspError.connectTimeout(48010)) else {
            Issue.record("expected streamPortsBlocked")
            return
        }
        guard case .sessionFailed(454) = NativeBackend.mapToStreamError(
            RtspError.nonOK(step: "SETUP", code: 454)) else {
            Issue.record("expected sessionFailed(454)")
            return
        }
    }

    @Test func pairingResultsRequireCurrentAttemptAndHost() {
        let first = PairingAttempt(address: "first.local")
        let second = PairingAttempt(address: "second.local")
        let retry = PairingAttempt(address: "first.local")
        #expect(first.accepts(first, address: "first.local", cancelled: false))
        #expect(!first.accepts(second, address: "second.local", cancelled: false))
        #expect(!first.accepts(retry, address: "first.local", cancelled: false))
        #expect(!first.accepts(nil, address: "first.local", cancelled: false))
        #expect(!first.accepts(first, address: "second.local", cancelled: false))
        #expect(!first.accepts(first, address: "first.local", cancelled: true))
    }
}

private actor SafetyTestGate {
    private(set) var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for waiter in waiters { waiter.resume() }
        waiters.removeAll()
    }
}

private actor SafetyTestCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}
