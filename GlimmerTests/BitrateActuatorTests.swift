// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AVFoundation
import Foundation
import os
import Testing
@testable import GlimmerEngine

@Suite(.serialized)
struct BitrateActuatorTests {
    @Test func replacementReleasesHeldInputAndWaitsForPresentationBeforeRearming() throws {
        let old = InputRecordingBackend()
        let fresh = InputRecordingBackend()
        let input = StreamInput(emit: { _ in })
        let attempt = UUID()
        #expect(input.rebind(to: old, attempt: attempt))
        input.activate(true, attempt: attempt)
        input.setFocused(true)
        let registration = try #require(input.registerController(
            ControllerDescriptor(kind: .unknown, supportedButtons: [.a], capabilities: [])))
        input.core.withLock {
            input.core.releases.hold(.key(VKScanCode(vk: 0x57)))
            input.core.releases.hold(.mouse(1))
            input.core.releases.hold(.controller(0))
        }
        input.prepareForReplacement(attempt: attempt)
        old.stopConnection()
        #expect(old.keyboard.map(\.action) == [Int8(StreamProtocol.KEY_ACTION_UP)])
        #expect(old.pointer.count == 1)
        #expect(old.controllersAtStop.map(\.buttons) == [0])
        let next = UUID()
        #expect(input.rebind(to: fresh, attempt: next, holdActivation: true))
        input.activate(true, attempt: attempt)
        input.activate(true, attempt: next)
        #expect(!input.core.snapshot.ready)
        input.resumeAfterReplacement(attempt: next)
        #expect(input.core.snapshot.ready)
        #expect(input.core.snapshot.focused)
        #expect(input.registrations[registration.slot]?.identity == registration)
        #expect(input.core.snapshot.mask == 1)
        #expect(fresh.keyboard.allSatisfy { $0.action == Int8(StreamProtocol.KEY_ACTION_UP) })
        input.stop()
    }

    @Test func reconnectAudioRampIsContinuousAndStaysSilentUntilResumed() throws {
        let storage = AudioRenderStorage(channels: 1, capacity: 960)
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 960))
        buffer.frameLength = 960
        let samples = try #require(buffer.floatChannelData)
        samples[0].update(repeating: 1, count: 960)
        let queue = storage.queue
        #expect(Bool(queue.pointee.write(samples, frames: 960, isSilence: false)))
        queue.pointee.enabled.store(true, ordering: .releasing)
        queue.pointee.fadingOut.store(true, ordering: .releasing)
        #expect(Bool(queue.pointee.render(
            frames: 240, buffers: buffer.mutableAudioBufferList, hostTime: 100) == 0))
        #expect(samples[0][0] < 1 && abs(samples[0][239]) < 0.00001)
        for index in 1..<240 { #expect(abs(samples[0][index] - samples[0][index - 1]) < 0.00418) }
        for _ in 0..<2 {
            #expect(Bool(queue.pointee.render(
                frames: 240, buffers: buffer.mutableAudioBufferList, hostTime: 200) == 0))
            #expect(samples[0][0] == 0 && samples[0][239] == 0)
        }
        #expect(queue.pointee.firstRenderHostTime.load(ordering: .relaxed) == 100)
        #expect(queue.pointee.lastRenderHostTime.load(ordering: .relaxed) == 100)
        queue.pointee.fadingOut.store(false, ordering: .releasing)
        #expect(Bool(queue.pointee.render(
            frames: 240, buffers: buffer.mutableAudioBufferList, hostTime: 300) == 0))
        #expect(samples[0][0] < 0.00418 && abs(samples[0][239] - 1) < 0.00001)
        #expect(queue.pointee.lastRenderHostTime.load(ordering: .relaxed) == 300)
    }

    @Test(arguments: [StreamHostDisposition.cancelOwnedHostSession, .disconnectOnly])
    func resumeOnlyAppliesExactRateAndReportsMediaBoundary(disposition: StreamHostDisposition) async throws {
        let fixture = await BitrateFixture(disposition: disposition)
        #expect(await fixture.session.request(rate: 30_000, reason: .congestion) == .accepted)
        await fixture.session.waitForBitrateTask()
        #expect(fixture.pc.paths == ["serverinfo", "resume"])
        #expect(fixture.fresh.startedConfigs.map(\.bitrate) == [30_000])
        let config = try #require(fixture.fresh.startedConfigs.first)
        let sdp = SdpBuilder(config: config, videoPort: 48_000, urlSafeAddr: "192.0.2.10",
            addrFamilyToken: "IPv4", negotiatedVideoFormat: StreamProtocol.VIDEO_FORMAT_H264,
            encryptionFeaturesEnabled: 0).build()
        let payload = try #require(String(data: sdp, encoding: .utf8))
        #expect(payload.contains("x-ml-video.configuredBitrateKbps:30000"))
        #expect(fixture.fresh.startedServers.map(\.rtspSessionUrl) == [BitrateFixture.sessionURL])
        #expect(await fixture.session.appliedBitrateKbps == 30_000)
        let report = try #require(await fixture.session.lastBitrateChange)
        #expect(report.outcome == .applied && report.attempts == 1)
        #expect(report.reason == .congestion && report.fromKbps == 40_000)
        #expect(abs((report.videoGapMs ?? 0) - 120) < 0.001)
        #expect(report.audioGapMs == nil)
        #expect(abs((report.inputDisabledMs ?? 0) - 20) < 0.001)
        #expect(report.legs.keys.sorted() == [
            "first_frame_ms", "release_fade_ms", "resume_ms", "server_info_ms", "teardown_ms", "transport_ms"
        ])
        let data = try JSONEncoder().encode(report)
        let text = try #require(String(data: data, encoding: .utf8))
        #expect(!text.contains("Tower") && !text.contains("192.0.2"))
        #expect(fixture.quiesces.withLock { $0 } == 1)
        #expect(await fixture.session.request(rate: 30_000, reason: .trial) == .rejected)
        await fixture.stopLocally()
    }

    @Test func admissionDoesNotQueueOrRaceExistingRecovery() async {
        let fixture = await BitrateFixture()
        #expect(await fixture.session.request(rate: 0, reason: .trial) == .rejected)
        #expect(await fixture.session.request(rate: 40_000, reason: .trial) == .rejected)
        await fixture.session.setOwnershipForTest(false)
        #expect(await fixture.session.request(rate: 30_000, reason: .trial) == .deferred)
        await fixture.session.setOwnershipForTest(true)
        await fixture.session.setBitrateChangesAvailable(false)
        #expect(await fixture.session.request(rate: 30_000, reason: .trial) == .deferred)
        await fixture.session.setBitrateChangesAvailable(true)
        await fixture.session.markRecoveryBusy(true)
        #expect(await fixture.session.request(rate: 30_000, reason: .trial) == .deferred)
        await fixture.session.markRecoveryBusy(false)
        let admissions = await fixture.session.requestTwiceForTest()
        #expect(admissions == [.accepted, .deferred])
        await fixture.session.waitForBitrateTask()
        #expect(fixture.pc.paths == ["serverinfo", "resume"])
        await fixture.stopLocally()
    }

    @Test(arguments: [0, 9])
    func endedOrReplacedGameNeverLaunchesOrCancels(app: Int) async {
        let fixture = await BitrateFixture(app: app)
        #expect(await fixture.session.request(rate: 30_000, reason: .rollback) == .accepted)
        await fixture.session.waitForBitrateTask()
        #expect(fixture.pc.paths == ["serverinfo"])
        #expect(fixture.fresh.startedConfigs.isEmpty)
        #expect(await !fixture.session.isStreaming)
        #expect(await fixture.session.lastBitrateChange?.outcome == .failed)
    }

    @Test func failedTransportFallsBackWithinBudgetWithoutCancel() async {
        let fixture = await BitrateFixture(failing: true)
        #expect(await fixture.session.request(rate: 30_000, reason: .congestion) == .accepted)
        await fixture.session.waitForBitrateTask()
        #expect(fixture.pc.paths == Array(repeating: ["serverinfo", "resume"], count: 5).flatMap { $0 })
        #expect(await fixture.session.lastBitrateChange?.outcome == .failed)
        #expect(await fixture.session.lastBitrateChange?.attempts == 5)
        #expect(await fixture.session.appliedBitrateKbps == 40_000)
        #expect(await !fixture.session.isStreaming)
        var terminated = 0
        for await event in fixture.events {
            if case .connectionTerminated = event { terminated += 1 }
        }
        #expect(terminated == 1)
    }

    @Test func delayedIndicatorDoesNotCreateAnotherRecovery() async throws {
        let gate = BitrateTestGate()
        let fixture = await BitrateFixture(beforeConnect: { await gate.pause() })
        #expect(await fixture.session.request(rate: 30_000, reason: .trial) == .accepted)
        await gate.waitUntilEntered()
        await fixture.session.showBitrateRecovery()
        await fixture.session.showBitrateRecovery()
        await gate.release()
        await fixture.session.waitForBitrateTask()
        #expect(await fixture.session.lastBitrateChange?.indicatorShown == true)
        let bridge = try #require(await fixture.session.bridge)
        let attempt = bridge.currentAttempt
        #expect(bridge.acceptsInput(attempt: attempt))
        await fixture.stopLocally()
        bridge.beginAttempt(UUID())
        #expect(!bridge.acceptsInput(attempt: bridge.currentAttempt))
        var reconnecting = 0
        for await event in fixture.events {
            if case .reconnecting = event { reconnecting += 1 }
        }
        #expect(reconnecting == 1)
    }

    @Test func stopDuringReservedTransitionLeavesGameRunning() async {
        let fixture = await BitrateFixture()
        await fixture.session.reserveThenStopForTest()
        await fixture.session.waitForBitrateTask()
        #expect(!fixture.pc.paths.contains("cancel") && !fixture.pc.paths.contains("launch"))
        #expect(await !fixture.session.isStreaming)
        #expect(await fixture.session.lastBitrateChange?.outcome == .cancelled)
    }

    @Test func connectedTransportWithoutFreshPresentationNeverReportsApplied() async {
        let fixture = await BitrateFixture(present: false)
        #expect(await fixture.session.request(rate: 30_000, reason: .trial) == .accepted)
        await fixture.session.waitForBitrateTask()
        #expect(await fixture.session.lastBitrateChange?.outcome == .failed)
        #expect(await fixture.session.appliedBitrateKbps == 40_000)
        #expect(!fixture.pc.paths.contains("cancel") && !fixture.pc.paths.contains("launch"))
    }

    @Test(arguments: [false, true])
    func stopOrBackgroundDuringHandshakeCannotCancelGame(background: Bool) async {
        let gate = BitrateTestGate()
        let fixture = await BitrateFixture(beforeConnect: { await gate.pause() })
        #expect(await fixture.session.request(rate: 30_000, reason: .trial) == .accepted)
        await gate.waitUntilEntered()
        #expect(await fixture.session.request(rate: 20_000, reason: .rollback) == .deferred)
        if background {
            await fixture.session.setBitrateChangesAvailable(false)
        } else {
            await fixture.session.stop()
        }
        await gate.release()
        await fixture.session.waitForBitrateTask()
        #expect(fixture.pc.paths == ["serverinfo", "resume"])
        #expect(await fixture.session.lastBitrateChange?.outcome == .cancelled)
        #expect(await fixture.session.appliedBitrateKbps == 40_000)
        #expect(await !fixture.session.isStreaming)
    }
}

private actor BitrateTestGate {
    private var entered = false
    private var entry: CheckedContinuation<Void, Never>?
    private var paused: CheckedContinuation<Void, Never>?

    func pause() async {
        entered = true
        entry?.resume()
        entry = nil
        await withCheckedContinuation { paused = $0 }
    }

    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { entry = $0 }
    }

    func release() { paused?.resume(); paused = nil }
}

private struct BitrateFixture: Sendable {
    static let sessionURL = "rtsp://192.0.2.10:48010"
    let session: StreamSession
    let pc: FakeSunshine
    let fresh: InputRecordingBackend
    let events: AsyncStream<StreamEvent>
    let quiesces: OSAllocatedUnfairLock<Int>

    @MainActor
    init(disposition: StreamHostDisposition = .cancelOwnedHostSession, app: Int = 7,
         failing: Bool = false, present: Bool = true,
         beforeConnect: @escaping @Sendable () async throws -> Void = {}) async {
        let pc = FakeSunshine.scripted([
            "serverinfo": [.success(FakeSunshine.xml("<currentgame>\(app)</currentgame><PairStatus>1</PairStatus>"))],
            "resume": [.success(FakeSunshine.xml("<resume>1</resume><sessionUrl0>\(Self.sessionURL)</sessionUrl0>"))]
        ])
        self.pc = pc
        let configuration = StreamConnection.Configuration(width: 1920, height: 1080, fps: 60,
                                                           bitrateKbps: 40_000, videoFormats: .h264)
        let video = VideoDecoder(configuration: configuration, displayInfo: { nil })
        video.attach(to: AVSampleBufferDisplayLayer())
        let stats = video.statsCollector
        stats.lock.withLock { stats.firstPresentTime = 9; stats.lastPresentTime = 9.9 }
        let fresh = InputRecordingBackend(connectFailure: failing ? .sessionFailed(-1) : nil,
            beforeConnect: beforeConnect, onConnect: {
            stats.resetForConnection()
            if present { stats.lock.withLock { stats.firstPresentTime = 10.02; stats.lastPresentTime = 10.02 } }
        })
        self.fresh = fresh
        let time = OSAllocatedUnfairLock(initialState: UInt64(10_000_000_000))
        let clock = SessionClock(uptimeNanos: { time.withLock { $0 } }, sleep: { duration in
            if duration == .milliseconds(750) {
                let (stream, continuation) = AsyncStream<Void>.makeStream()
                defer { continuation.finish() }
                for await _ in stream { }
                throw CancellationError()
            }
            try Task.checkCancellation()
            time.withLock { $0 += UInt64(duration / .seconds(1) * 1_000_000_000) }
        })
        let quiesces = OSAllocatedUnfairLock(initialState: 0)
        self.quiesces = quiesces
        let hooks = SessionInputHooks(setBackend: { _ in }, setReady: { _ in },
            quiesce: { quiesces.withLock { $0 += 1 } }, detach: {}, configure: { _ in })
        let audio = AudioDecoder(platform: Self.dormantAudio())
        let session = StreamSession(hostDisposition: disposition, audioDecoder: audio, services: SessionServices(),
            backend: InputRecordingBackend(), makeNetwork: { pc.client($0) }, makeBackend: { fresh }, clock: clock)
        self.session = session
        events = await session.prepareBitrateTest(video: video, audio: audio, hooks: hooks,
            server: FakeSunshine.server(pin: "host-pin"), request: configuration.request)
    }

    func stopLocally() async {
        await session.setOwnershipForTest(false)
        await session.stop()
    }

    private static func dormantAudio() -> AudioPlatform {
        AudioPlatform(makeOutput: { _ in throw CancellationError() },
            sampleRoute: { AudioRoute(label: "unused", uid: nil) }, installRouteListener: { _, _, _ in },
            removeRouteListener: { _ in }, installDeviceListeners: { _, _ in }, removeDeviceListeners: {},
            captureVolume: { { AudioOutputVolume(volume: nil, muted: nil, routeChanged: false) } },
            environment: { AudioEnvironment(host: "unused", link: "unknown", jitterMs: 0) })
    }
}

private extension StreamSession {
    func prepareBitrateTest(video: VideoDecoder, audio: AudioDecoder, hooks: SessionInputHooks,
                            server: ServerInfo, request: StreamRequest) async -> AsyncStream<StreamEvent> {
        isStreaming = true
        reachedLiveState = true
        ownsHostSession = true
        reconnectServer = server
        reconnectConfig = request
        reconnectAppID = 7
        appliedBitrateKbps = 40_000
        input = hooks
        videoDecoder = video
        presentation = await SessionPresentation()
        let bridge = StreamBridgeContext(session: self, videoDecoder: video, audioDecoder: audio)
        let pair = AsyncStream<StreamEvent>.makeStream()
        bridge.eventContinuation = pair.continuation
        self.bridge = bridge
        return pair.stream
    }

    func markRecoveryBusy(_ value: Bool) { isReconnecting = value }
    func setOwnershipForTest(_ owned: Bool) { ownsHostSession = owned }
    func waitForBitrateTask() async { await bitrateTask?.value }

    func requestTwiceForTest() -> [BitrateAdmission] {
        [request(rate: 30_000, reason: .trial), request(rate: 20_000, reason: .rollback)]
    }

    func reserveThenStopForTest() async {
        #expect(request(rate: 30_000, reason: .trial) == .accepted)
        await stop()
    }
}
