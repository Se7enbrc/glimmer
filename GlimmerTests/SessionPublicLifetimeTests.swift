// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

@testable import GlimmerEngine
@testable import Glimmer
import Foundation
import os
import Testing

@Suite(.serialized)
struct SessionPublicLifetimeTests {
    private var configuration: StreamConnection.Configuration {
        .init(width: 1920, height: 1080, fps: 60, bitrateKbps: 20_000, videoFormats: .h264)
    }

    @Test func stopBeforeStartRevokesInputAndFinishesOnlyAfterNativeDisposal() async throws {
        let sunshine = FakeSunshine.scripted([:])
        let entered = SafetyTestGate()
        let release = SafetyTestGate()
        let disposed = SafetyTestCounter()
        let pair = await MainActor.run {
            let media = StreamSession.PreparedMedia(video: VideoDecoder(), audio: AudioDecoder(), quiesce: {},
                finalDispose: {
                    await entered.open()
                    await release.wait()
                    await disposed.increment()
                })
            return StreamSession.make(media: media, network: sunshine.client(SessionFlow.pairedPC()),
                                      hostDisposition: .disconnectOnly)
        }
        let stopping = Task { await pair.session.stop() }
        await entered.wait()
        #expect(pair.input.registerController(.init(kind: .unknown, supportedButtons: [.a], capabilities: [])) == nil)
        await #expect(throws: CancellationError.self) {
            try await pair.session.start(appID: 7, configuration: configuration)
        }
        #expect(sunshine.paths.isEmpty)
        #expect(await disposed.value == 0)
        await release.open()
        await stopping.value
        await pair.session.stop()
        #expect(await disposed.value == 1)
        var completed = 0
        for await update in pair.session.events {
            #expect(update.sessionID == pair.session.id)
            #expect(completed == 0)
            switch update.event {
            case .stopped: completed += 1
            case .input(.controllersActive(false)): break
            default: Issue.record("Unexpected event before a stopped session ever started")
            }
        }
        #expect(completed == 1)
        #expect(await !pair.session.stopInProgress)
    }

    @Test(arguments: [0, 7])
    func publicStartKeepsCachedRequestCountAndLocalStop(runningApp: Int) async throws {
        let sunshine = FakeSunshine.scripted(["launch": [Self.launched()], "resume": [Self.launched()]])
        var server = SessionFlow.pairedPC()
        server.currentGameID = runningApp
        server.pairStatus = .paired
        let network = sunshine.client(server)
        let disposal = SafetyTestCounter()
        let pair = await MainActor.run {
            StreamSession.make(media: .init(video: VideoDecoder(), audio: AudioDecoder(), quiesce: {},
                finalDispose: { await disposal.increment() }), network: network, hostDisposition: .disconnectOnly)
        }
        let backend = InputRecordingBackend()
        await pair.session.installPublicTestBackend(backend)
        try await pair.session.start(appID: 7, configuration: configuration)
        await pair.session.stop()
        #expect(sunshine.paths == [runningApp == 7 ? "resume" : "launch"])
        #expect(await disposal.value == 1)
        #expect(pair.input.core.backend == nil)
    }

    private static func launched(key: String = "000102030405060708090a0b0c0d0e0f",
                                 iv: String = "a0a1a2a3000000000000000000000000") -> Result<ControlTransport.Response, StreamError> {
        .success(FakeSunshine.xml("""
            <root status_code="200"><sessionUrl0>\(SessionFlow.sessionURL)</sessionUrl0>
            <gcmkey>\(key)</gcmkey><gcmkeyid>\(iv)</gcmkeyid></root>
            """))
    }

    @Test(arguments: [false, true])
    func malformedPublicLaunchKeyNeverStartsTransport(shortKey: Bool) async {
        let response = shortKey ? Self.launched(key: "00010203") : Self.launched(iv: "00010203")
        let sunshine = FakeSunshine.scripted(["launch": [response]])
        var server = SessionFlow.pairedPC()
        server.pairStatus = .paired
        let disposal = SafetyTestCounter()
        let pair = await MainActor.run {
            StreamSession.make(media: .init(video: VideoDecoder(), audio: AudioDecoder(), quiesce: {},
                finalDispose: { await disposal.increment() }), network: sunshine.client(server),
                hostDisposition: .disconnectOnly)
        }
        let backend = InputRecordingBackend()
        await pair.session.installPublicTestBackend(backend)
        do {
            try await pair.session.start(appID: 7, configuration: configuration)
            Issue.record("Malformed session key was accepted")
        } catch StreamConnection.Failure.invalidSessionKey {} catch { Issue.record("Unexpected error: \(error)") }
        #expect(backend.startedServers.isEmpty)
        #expect(sunshine.paths == ["launch"])
        #expect(await disposal.value == 1)
        #expect(pair.input.core.backend == nil)
    }

    @Test func suppliedMTUSurvivesCanonicalConfigurationAndRecovery() async throws {
        let sunshine = FakeSunshine.scripted(["launch": [Self.launched()]])
        var server = SessionFlow.pairedPC()
        server.pairStatus = .paired
        let pair = await MainActor.run {
            StreamSession.make(media: .init(video: VideoDecoder(), audio: AudioDecoder(), quiesce: {}, finalDispose: {}),
                               network: sunshine.client(server), hostDisposition: .disconnectOnly)
        }
        let backend = InputRecordingBackend()
        await pair.session.installPublicTestBackend(backend)
        let config = StreamConnection.Configuration(width: 1920, height: 1080, fps: 60, bitrateKbps: 20_000,
                                                     videoFormats: .h264, remote: true, routeMTU: 1000)
        try await pair.session.start(appID: 7, configuration: config)
        let launch = LaunchResponse(sessionURL: "", gcmKey: Data(repeating: 0, count: 16),
                                    gcmKeyId: Data(repeating: 0, count: 16))
        let expected = try config.backendConfig(launch: launch)
        #expect(expected.packetSize < 1024)
        #expect(backend.startedConfigs.first?.packetSize == expected.packetSize)
        let recovery = await pair.session.makeBackendConfig(config: config.request, launch: launch, server: server)
        #expect(recovery.packetSize == expected.packetSize)
        await pair.session.stop()
    }

    @Test func liveVideoHoldPublishesOnlyTransitionsAndPreservesInput() async throws {
        let backend = InputRecordingBackend()
        let source = SessionEventSource()
        let stream = source.stream
        let input = StreamInput { source.yield(.input($0)) }
        let media = await MainActor.run {
            StreamSession.PreparedMedia(video: VideoDecoder(), audio: AudioDecoder(), quiesce: {}, finalDispose: {})
        }
        let session = StreamSession(hostDisposition: .disconnectOnly, audioDecoder: await media.audio,
            services: SessionServices(), backend: backend, makeNetwork: { FakeSunshine.scripted([:]).client($0) },
            makeBackend: { InputRecordingBackend() }, publicMedia: media, publicInput: input, events: source)
        let attempt = await session.preparePublicRecoveryTest()
        #expect(input.rebind(to: backend, attempt: attempt))
        input.activate(true, attempt: attempt)
        await session.holdForAliveLink(decodeIdle: 12, receiveIdle: 12, ackMs: 1)
        await session.holdForAliveLink(decodeIdle: 13, receiveIdle: 13, ackMs: 1)
        #expect(input.core.snapshot.ready)
        await session.clearDecodeOnlyStallLatch()
        await session.clearDecodeOnlyStallLatch()
        #expect(input.core.snapshot.ready)
        await session.stop()
        var holds: [Bool] = []
        for await update in stream {
            if case .waitingForVideo(let held) = update.event { holds.append(held) }
        }
        #expect(holds == [true, false])
    }

    @Test func stoppedDuringNativeConfigLoggingNeverBeginsMediaPreparation() async {
        let sunshine = FakeSunshine.scripted(["serverinfo": [SessionFlow.idle], "launch": [SessionFlow.launched]])
        let entered = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let preparations = OSAllocatedUnfairLock(initialState: 0)
        var services = SessionServices()
        services.logConfig = { _ in
            entered.continuation.yield(())
            entered.continuation.finish()
            #expect(release.wait(timeout: .now() + 10) == .success)
        }
        let session = StreamSession(hostDisposition: .disconnectOnly, audioDecoder: AudioDecoder(), services: services,
            backend: InputRecordingBackend(), makeNetwork: { sunshine.client($0) },
            makeBackend: { InputRecordingBackend() })
        let starting = Task {
            try await session.start(server: SessionFlow.pairedPC(), request: SessionFlow.config.request, appID: 7,
                prepare: { _ in
                    preparations.withLock { $0 += 1 }
                    throw StreamError.launchFailed("Unexpected media preparation")
                })
        }
        for await _ in entered.stream { break }
        let stopping = Task { await session.stop() }
        let deadline = ContinuousClock.now + .seconds(2)
        while await !session.stopInProgress, ContinuousClock.now < deadline { await Task.yield() }
        #expect(await session.stopInProgress)
        release.signal()
        await stopping.value
        await #expect(throws: CancellationError.self) { _ = try await starting.value }
        #expect(preparations.withLock { $0 } == 0)
        #expect(sunshine.paths == ["serverinfo", "launch"])
    }

    @Test func stopWaitsForAnAlreadyRunningNativePreparationAndDisposesItsResult() async throws {
        let sunshine = FakeSunshine.scripted(["serverinfo": [SessionFlow.idle], "launch": [SessionFlow.launched]])
        let backend = InputRecordingBackend()
        let session = StreamSession(hostDisposition: .disconnectOnly, backend: backend,
                                    makeNetwork: { sunshine.client($0) })
        let entered = AsyncStream<Void>.makeStream()
        let release = DispatchSemaphore(value: 0)
        let setup = await MainActor.run {
            let window = StreamWindow(displayMode: .window)
            let input = InputForwarder()
            let video = VideoDecoder()
            return (window, SessionMedia(presentation: SessionPresentation(window),
                                        input: SessionInputHooks(input), video: video))
        }
        let starting = Task {
            try await session.start(server: SessionFlow.pairedPC(), request: SessionFlow.config.request, appID: 7,
                prepare: { _ in
                    entered.continuation.yield(())
                    entered.continuation.finish()
                    #expect(release.wait(timeout: .now() + 10) == .success)
                    return setup.1
                })
        }
        for await _ in entered.stream { break }
        let finished = SafetyTestCounter()
        let stopping = Task { await session.stop(); await finished.increment() }
        let deadline = ContinuousClock.now + .seconds(2)
        while await !session.stopInProgress, ContinuousClock.now < deadline { await Task.yield() }
        #expect(await session.stopInProgress)
        #expect(await finished.value == 0)
        release.signal()
        await stopping.value
        await #expect(throws: CancellationError.self) { _ = try await starting.value }
        #expect(await setup.0.didClose)
        #expect(await session.presentation == nil)
        #expect(await session.videoDecoder == nil)
        #expect(backend.startedServers.isEmpty)
        #expect(sunshine.paths == ["serverinfo", "launch"])
    }

    @Test func selfInitiatedRecoveryRevokesPublicInputBeforeItsFirstBackoff() async throws {
        let entered = SafetyTestGate()
        let release = SafetyTestGate()
        let backend = InputRecordingBackend()
        let source = SessionEventSource()
        let stream = source.stream
        let input = StreamInput { source.yield(.input($0)) }
        let media = await MainActor.run {
            StreamSession.PreparedMedia(video: VideoDecoder(), audio: AudioDecoder(), quiesce: {}, finalDispose: {})
        }
        let sunshine = FakeSunshine.scripted([:])
        let network = sunshine.client(SessionFlow.pairedPC())
        let clock = SessionClock(sleep: { _ in await entered.open(); await release.wait() })
        let session = StreamSession(hostDisposition: .disconnectOnly, audioDecoder: await media.audio,
            services: SessionServices(), backend: backend, makeNetwork: { network.freshClient(for: $0) },
            makeBackend: { InputRecordingBackend() }, clock: clock,
            publicMedia: media, publicInput: input, preparedNetwork: network, events: source)
        let registration = try #require(input.registerController(.init(kind: .unknown,
            supportedButtons: [.a], capabilities: [])))
        let attempt = await session.preparePublicRecoveryTest()
        #expect(input.rebind(to: backend, attempt: attempt))
        input.setFocused(true)
        input.activate(true, attempt: attempt)
        input.submitController(registration, sample: .init(buttons: .a),
                               capturedAt: ProcessInfo.processInfo.systemUptime)
        let recovering = Task { await session.runSelfInitiatedReconnect(cause: "test") }
        await entered.wait()
        #expect(input.core.backend == nil)
        #expect(input.registrations[registration.slot]?.identity == registration)
        #expect(backend.calls.map(\.buttons) == [ControllerButtons.a.rawValue, 0])
        input.enqueueActivation(true, attempt: attempt)
        input.lifecycleQueue.sync {}
        input.submitController(registration, sample: .init(buttons: .a),
                               capturedAt: ProcessInfo.processInfo.systemUptime)
        #expect(backend.calls.count == 2)
        await session.stop()
        await release.open()
        await recovering.value
        var reconnects = 0
        for await update in stream { if case .reconnecting = update.event { reconnects += 1 } }
        #expect(reconnects == 1)
        #expect(sunshine.paths.isEmpty)
    }

    @Test func slowConsumerRetainsOrderAndRejectsOldAttemptEvents() async {
        let source = SessionEventSource()
        let stream = source.stream
        let first = UUID()
        source.beginAttempt(first)
        source.yield(.stageStarting(name: "old"), attempt: first)
        let second = UUID()
        source.beginAttempt(second)
        source.yield(.firstFrame, attempt: first)
        source.yield(.stageComplete(name: "new"), attempt: second)
        source.yield(.stopped, attempt: second)
        source.finish()
        source.yield(.connectionEstablished, attempt: second)
        var events: [String] = []
        var identities: [UUID] = []
        for await update in stream {
            identities.append(update.attemptID)
            switch update.event {
            case .stageStarting(let name), .stageComplete(let name): events.append(name)
            case .stopped: events.append("stopped")
            default: Issue.record("Stale or post-completion event escaped")
            }
        }
        #expect(events == ["old", "new", "stopped"])
        #expect(identities == [first, second, second])
    }

    @Test @MainActor func oldMediaCallbacksCannotPromoteAReplacementAttempt() async throws {
        let session = StreamSession(hostDisposition: .cancelOwnedHostSession)
        let video = VideoDecoder()
        let source = SessionEventSource()
        let stream = source.stream
        let bridge = StreamBridgeContext(session: session, videoDecoder: video, audioDecoder: AudioDecoder(),
                                         publicEvents: source)
        let media = SessionMedia(presentation: SessionPresentation(), input: SessionInputHooks(
            setBackend: { _ in }, setReady: { _ in }, quiesce: {}, detach: {}, configure: { _ in }), video: video)
        let first = UUID()
        bridge.beginAttempt(first)
        session.wireSubsystemBackends(setup: media, bridge: bridge, backend: InputRecordingBackend(), attempt: first)
        let oldFirst = try #require(video.onFirstDecodedFrame)
        let oldHDR = try #require(video.onHDRActiveChanged)
        let second = UUID()
        bridge.beginAttempt(second)
        session.wireSubsystemBackends(setup: media, bridge: bridge, backend: InputRecordingBackend(), attempt: second)
        oldFirst()
        oldHDR(true)
        video.onFirstDecodedFrame?()
        video.onHDRActiveChanged?(false)
        bridge.finishEvents()
        var seen: [UUID] = []
        for await event in stream { seen.append(event.attemptID) }
        #expect(seen == [second, second])
        video.teardown()
    }
}

private extension StreamSession {
    func preparePublicRecoveryTest() async -> UUID {
        isStreaming = true
        reachedLiveState = true
        guard let media = publicMedia else { return attemptID }
        let video = await media.video
        videoDecoder = video
        bridge = StreamBridgeContext(session: self, videoDecoder: video, audioDecoder: audioDecoder,
                                     publicEvents: eventSource)
        bridge?.beginAttempt(attemptID)
        return attemptID
    }

    func installPublicTestBackend(_ backend: any StreamingBackend) { self.backend = backend }
}
