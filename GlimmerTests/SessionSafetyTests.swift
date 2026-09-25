import Foundation
import os
import Testing
@testable import Glimmer

struct SessionSafetyTests {
    @Test func stoppedBackendReleasesTheVideoSink() {
        weak var releasedBackend: NativeBackend?
        weak var released: StubVideoSink?
        do {
            let backend = NativeBackend()
            releasedBackend = backend
            do {
                let sink = StubVideoSink(backend: backend)
                released = sink
                backend.attachVideoSink(sink)
            }
            #expect(released != nil)
            backend.stopConnection()
            #expect(released == nil)
        }
        #expect(releasedBackend == nil)
    }

    @Test(arguments: [false, true])
    func stoppedBackendRejectsLateSinks(interruptOnly: Bool) {
        let backend = NativeBackend()
        if interruptOnly { backend.interruptConnection() } else { backend.stopConnection() }
        weak var video: StubVideoSink?
        weak var audio: AudioDecoder?
        do {
            let videoSink = StubVideoSink()
            let audioSink = AudioDecoder()
            video = videoSink
            audio = audioSink
            backend.attachVideoSink(videoSink)
            backend.attachAudioSink(audioSink)
        }
        #expect(video == nil)
        #expect(audio == nil)
    }

    @Test func stoppingBackendInterruptsConnect() {
        let backend = NativeBackend()
        #expect(!backend.checkInterrupted())
        backend.stopConnection()
        #expect(backend.checkInterrupted())
        #expect(!backend.adoptWhileConnecting { Issue.record("Stopped backend published startup state") })
    }

    @Test(arguments: [false, true])
    func stopDuringVideoStartupCleansTheSink(duringSetup: Bool) async throws {
        let backend = NativeBackend()
        let sink = StubVideoSink(onSetup: { if duringSetup { backend.stopConnection() } },
                                 onStart: { if !duringSetup { backend.stopConnection() } })
        backend.attachVideoSink(sink)
        let config = BackendStreamConfig(
            width: 1920, height: 1080, fps: 60, bitrate: 20000, packetSize: 1392,
            streamingRemotely: 0, audioConfiguration: 0, supportedVideoFormats: 1,
            clientRefreshRateX100: 6000, colorSpace: 0, colorRange: 0, encryptionFlags: 0,
            remoteInputAesKey: [UInt8](repeating: 0, count: 16), remoteInputAesIv: [])
        let handshake = RtspHandshakeResult(
            audioPort: 0, videoPort: 0, controlPort: 0, controlConnectData: 0,
            sessionId: "", negotiatedVideoFormat: 1, encryptionFeaturesSupported: 0,
            encryptionFeaturesEnabled: 0, referenceFrameInvalidationSupported: false)
        let enet = EnetControlChannel(host: .ipv4(.loopback), port: 0,
                                      controlConnectData: 0, crypto: try ControlCrypto(rikey: config.remoteInputAesKey))
        backend.withState { backend.enetChannel = enet }
        do {
            try await backend.startVideoStage(handshake: handshake, config: config,
                                              host: .ipv4(.loopback), events: NativeConnectionEvents())
            Issue.record("Stopped video startup succeeded")
        } catch {
            guard case .interrupted = error as? EnetError else {
                Issue.record("Expected interruption, got \(error)")
                return
            }
        }
        #expect(!sink.running.withLock { $0 })
        #expect(backend.withState { backend.videoReceiver == nil && backend.videoSink == nil })
    }

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

    /// Cancellation must promptly wake a blocked control read and close the peer connection.
    @Test func cancelClosesBlockedControlRequest() async throws {
        try await Task(priority: .high) {
            let port = try #require(LoopbackPort(listening: true))
            let portNumber = Int(port.port)
            let requestFinished = ManagedAtomicFlag()
            let task = Task {
                defer { requestFinished.set() }
                do {
                    _ = try await ControlTransport.get(
                        host: "127.0.0.1", port: portNumber, target: "/serverinfo", userAgent: "GlimmerTests",
                        tls: false, credential: .init(clientCertPEM: nil, clientKeyPEM: nil, pinnedCertPEM: nil),
                        timeout: 10)
                    Issue.record("Cancelled control request returned a response")
                } catch {
                    let finishedAt = ContinuousClock.now
                    #expect(error is CancellationError)
                    return finishedAt
                }
                return ContinuousClock.now
            }
            defer { task.cancel() }
            let listener = port.fd
            let peer = try await acceptControlConnection(on: listener, requestFinished: requestFinished)
            defer { close(peer) }
            let cancelledAt = ContinuousClock.now
            task.cancel()
            // Only has to beat the request's 10s timeout; a tighter limit would time a busy test pool.
            #expect(await task.value - cancelledAt < .seconds(5))
            #expect(try await onTestThread { controlPeerReachesEOF(peer, before: cancelledAt + .seconds(5)) })
        }.value
    }

    /// A stalled control read must report the deadline's timeout, not an early socket error.
    @Test func stalledControlReadReportsTheTimeout() async throws {
        for _ in 0..<8 {
            let port = try #require(LoopbackPort(listening: true))
            let portNumber = Int(port.port)
            let deadline = Date().addingTimeInterval(0.03)
            do {
                _ = try await StreamAttempt.run(until: deadline) {
                    try await ControlTransport.get(
                        host: "127.0.0.1", port: portNumber, target: "/serverinfo", userAgent: "GlimmerTests",
                        tls: false, credential: .init(clientCertPEM: nil, clientKeyPEM: nil, pinnedCertPEM: nil),
                        timeout: max(0.001, deadline.timeIntervalSinceNow))
                }
                Issue.record("Stalled control request returned a response")
            } catch StreamError.hostTimedOut {
                continue
            } catch {
                Issue.record("Stalled control request reported \(error) instead of a timeout")
            }
        }
    }

    /// Control sockets must suppress SIGPIPE so a closed peer cannot terminate the app.
    @Test func controlSocketSuppressesSIGPIPE() async throws {
        let port = try #require(LoopbackPort(listening: true))
        let portNumber = String(port.port)
        let fd = try await onTestThread { gl_tcp_connect("127.0.0.1", portNumber, 1000) }
        try #require(fd >= 0)
        defer { close(fd) }
        var enabled: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        #expect(getsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, &length) == 0)
        #expect(enabled != 0)
    }

    /// A hostname must reach an IPv4-only listener even when it also resolves to IPv6.
    @Test func localhostReachesAnIPv4OnlyListener() async throws {
        let port = try #require(LoopbackPort(listening: true))
        let portNumber = String(port.port)
        let fd = try await onTestThread { gl_tcp_connect("localhost", portNumber, 2000) }
        try #require(fd >= 0)
        close(fd)
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
        await Task(priority: .high) {
            let release = SafetyTestGate()
            let unwound = SafetyTestGate()
            let entered = SafetyTestGate()
            let mutations = SafetyTestCounter()
            let waiting = ManagedAtomicFlag()
            // The request is running before the deadline is armed, and 300ms leaves the
            // operation time to start under load, so the timeout interrupts real work.
            let request = Task {
                await entered.open()
                await release.wait()
            }
            await entered.wait()
            let started = ContinuousClock.now
            do {
                try await StreamAttempt.run(until: Date().addingTimeInterval(0.3)) {
                    waiting.set()
                    defer { Task { await unwound.open() } }
                    await request.value
                    try Task.checkCancellation()
                    await mutations.increment()
                }
                Issue.record("Request outlived its deadline")
            } catch StreamError.hostTimedOut {
                // The request can't finish until released, so this limit only catches a hang.
                let returned = ContinuousClock.now
                #expect(returned - started < .seconds(5))
                #expect(waiting.isSet)
                #expect(await entered.isOpen)
                #expect(await !release.isOpen)
                #expect(await !unwound.isOpen)
            } catch {
                Issue.record("Expected the deadline timeout, got \(error)")
            }
            await release.open()
            await request.value
            if waiting.isSet { await unwound.wait() }
            #expect(await mutations.value == 0)
        }.value
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
            (StreamError.truncatedRead("recv timeout"), .unreachable, AppModel.unreachableMessage("Tower")),
            (StreamError.gameStreamHost, .pairing, "Glimmer needs Sunshine on Tower, which is running NVIDIA GameStream.")
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

actor SafetyTestGate {
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

actor SafetyTestCounter {
    private(set) var value = 0
    func increment() { value += 1 }
}

private final class StubVideoSink: VideoSink {
    let backend: NativeBackend?
    let running = OSAllocatedUnfairLock(initialState: false)
    let onSetup: @Sendable () -> Void
    let onStart: @Sendable () -> Void
    var capabilities: Int32 { 0 }
    init(backend: NativeBackend? = nil,
         onSetup: @escaping @Sendable () -> Void = {}, onStart: @escaping @Sendable () -> Void = {}) {
        self.backend = backend
        self.onSetup = onSetup
        self.onStart = onStart
    }
    func setup(videoFormat: Int32, width: Int32, height: Int32, redrawRate: Int32) -> Int32 {
        onSetup()
        return 0
    }
    func start() {
        onStart()
        running.withLock { $0 = true }
    }
    func stop() { running.withLock { $0 = false } }
    func cleanup() {}
    func submitDecodeUnit(_ unit: DecodeUnit) -> Int32 { StreamProtocol.DR_OK }
}
