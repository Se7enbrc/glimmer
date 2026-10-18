// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  BackendGlueTests.swift
//
//  The glue between the native engine and the session: connection events
//  reaching the bridge's stream, the bridge pointer, RTSP URL parsing and the
//  protocol's default async connect.
//

@testable import GlimmerEngine
import Foundation
import Testing
@testable import Glimmer

@MainActor
struct BackendGlueTests {

    private func label(_ event: StreamEvent) -> String {
        switch event {
        case .stageStarting(let name): return "start \(name)"
        case .stageComplete(let name): return "done \(name)"
        case .stageFailed(let name, let code): return "fail \(name) \(code)"
        case .connectionEstablished: return "established"
        case .connectionTerminated(let code, _): return "terminated \(code)"
        case .connectionStatus(let quality): return "status \(quality == .poor ? "poor" : "good")"
        case .hdrModeChanged(let enabled): return "hdr \(enabled)"
        default: return "other"
        }
    }

    /// With no session left to classify it, a terminate still reaches the UI.
    @Test func eventsReachTheBridgeStreamInOrder() async {
        let session = StreamSession(hostDisposition: .cancelOwnedHostSession, backend: InputRecordingBackend())
        let bridge = StreamBridgeContext(
            session: session, videoDecoder: VideoDecoder(), audioDecoder: AudioDecoder())
        let (stream, continuation) = AsyncStream.makeStream(of: StreamEvent.self)
        bridge.eventContinuation = continuation
        bridge.session = nil
        let events = NativeConnectionEvents(bridge: bridge)
        events.stageStarting("audio stream")
        events.stageComplete("audio stream")
        events.stageFailed("video stream", code: -3)
        events.connectionStatus(poor: true)
        events.connectionStatus(poor: false)
        events.setHdrMode(true)
        events.connectionStarted()
        events.connectionTerminated(code: 7)
        continuation.finish()
        var labels: [String] = []
        for await event in stream { labels.append(label(event)) }
        #expect(labels == [
            "start audio stream", "done audio stream", "fail video stream -3",
            "status poor", "status good", "hdr true", "established", "terminated 7"
        ])
    }

    @Test func bridgePointerResolvesToTheSameBridge() {
        let bridge = StreamBridgeContext(
            session: StreamSession(
                hostDisposition: .cancelOwnedHostSession, backend: InputRecordingBackend()), videoDecoder: VideoDecoder(),
            audioDecoder: AudioDecoder())
        let pointer = Unmanaged.passUnretained(bridge).toOpaque()
        #expect(StreamBridgeContext.from(pointer) === bridge)
        #expect(StreamBridgeContext.from(nil) == nil)
    }

    @Test func rtspPortIsTheUrlsLastNumberOrTheDefault() {
        #expect(NativeBackend.rtspPort(from: "rtsp://192.0.2.1:48011") == 48011)
        #expect(NativeBackend.rtspPort(from: "rtsp://[fe80::1]:50000/path") == 50000)
        #expect(NativeBackend.rtspPort(from: "rtsp://192.0.2.1") == 48010)
        #expect(NativeBackend.rtspPort(from: "rtsp://192.0.2.1:70000") == 48010)
        #expect(NativeBackend.rtspPort(from: "rtsp://192.0.2.1:0") == 48010)
    }

    @Test func hostPortionStripsSchemePortAndPath() {
        #expect(NativeBackend.hostPortion(of: "rtsp://192.0.2.1:48010/stream") == "192.0.2.1")
        #expect(NativeBackend.hostPortion(of: "rtsp://[fe80::1]:48010") == "fe80::1")
        #expect(NativeBackend.hostPortion(of: "rtsp://[fe80::1") == "[fe80::1")
        #expect(NativeBackend.hostPortion(of: "rtsp://den-pc") == "den-pc")
        #expect(NativeBackend.hostPortion(of: "den-pc:48010") == nil)
    }

    /// The protocol's default async connect runs the backend's blocking start.
    @Test func defaultAsyncConnectRunsTheBlockingStart() async throws {
        let backend = InputRecordingBackend()
        let server = BackendServerInfo(
            address: "192.0.2.1", appVersion: "7.1.431.-1",
            rtspSessionUrl: "rtsp://192.0.2.1:48010", serverCodecModeRaw: 0x0101)
        let config = BackendStreamConfig(
            width: 1920, height: 1080, fps: 60, bitrate: 20_000, packetSize: 1392,
            streamingRemotely: StreamProtocol.STREAM_CFG_LOCAL, audioConfiguration: 0,
            supportedVideoFormats: 0, clientRefreshRateX100: 6000, colorSpace: 0, colorRange: 0,
            encryptionFlags: 0, remoteInputAesKey: [], remoteInputAesIv: [])
        try await backend.startConnectionAsync(server: server, config: config)
        let started = try #require(backend.startedServers.first)
        #expect(backend.startedServers.count == 1)
        #expect(started.rtspSessionUrl == "rtsp://192.0.2.1:48010")
        #expect(started.serverCodecModeRaw == 0x0101)
        #expect(backend.enetHealth() == nil)
    }
}

extension BackendGlueTests {
    @Test func retiredAttemptCannotApplyQueuedHdrOrFeedbackBeforeSourceSwap() async {
        let session = StreamSession(hostDisposition: .cancelOwnedHostSession, backend: InputRecordingBackend())
        let decoder = VideoDecoder()
        let activations = AtomicCounter()
        var feedback = SessionFeedback()
        feedback.activated = { _ in activations.increment() }
        let bridge = StreamBridgeContext(session: session, videoDecoder: decoder,
                                         audioDecoder: AudioDecoder(), feedback: feedback)
        let backend = NativeBackend()
        bridge.setEventSource(backend)
        let events = NativeConnectionEvents(bridge: bridge, backend: backend)
        events.setHdrMode(true)
        events.controllersActivated()
        #expect(activations.value == 1)
        bridge.beginAttempt(UUID())
        events.controllersActivated()
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(activations.value == 1)
        #expect(!decoder.hdrEnabled)
    }

    @Test func obsoleteBackendCannotPublishHdrOrAudioIntoReplacement() async {
        let session = StreamSession(hostDisposition: .cancelOwnedHostSession, backend: InputRecordingBackend())
        let decoder = VideoDecoder()
        let bridge = StreamBridgeContext(session: session, videoDecoder: decoder,
                                         audioDecoder: AudioDecoder())
        let old = NativeBackend()
        let replacement = NativeBackend()
        let (stream, continuation) = AsyncStream.makeStream(of: StreamEvent.self)
        bridge.eventContinuation = continuation
        bridge.setEventSource(old)
        let events = NativeConnectionEvents(bridge: bridge, backend: old)
        events.setHdrMode(true)
        bridge.setEventSource(replacement)
        events.setHdrMode(false)
        events.audioFailed("stale audio")
        events.connectionStarted()
        continuation.finish()
        var received: [String] = []
        for await event in stream { received.append(label(event)) }
        #expect(received == ["hdr true"])
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        #expect(!decoder.hdrEnabled)
    }
}

struct NativeBackendTeardownTests {
    @Test func stopJoinsVideoStartupBeforeTheSinkCanBeReused() async throws {
        let backend = NativeBackend()
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let stopEntered = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0)
        let sink = TeardownVideoSink(onSetup: {
            entered.signal()
            release.wait()
        }, onCleanup: {})
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
        let startup = Task.detached {
            try await backend.startVideoStage(handshake: handshake, config: config,
                                              host: .ipv4(.loopback), events: NativeConnectionEvents())
        }
        defer { release.signal() }
        try #require(await entered.waitAsync(for: .seconds(5)) == .success)
        backend.interruptConnection()
        Thread {
            stopEntered.signal()
            backend.stopConnection()
            stopped.signal()
        }.start()
        try #require(await stopEntered.waitAsync(for: .seconds(5)) == .success)
        #expect(await stopped.waitAsync(for: .milliseconds(100)) == .timedOut)
        release.signal()
        try #require(await stopped.waitAsync(for: .seconds(5)) == .success)
        await #expect(throws: (any Error).self) { try await startup.value }
        sink.start()
        #expect(backend.withState { backend.videoReceiver == nil && backend.videoSink == nil })
    }

    @Test func overlappingStopWaitsForTheFirstResourceCleanup() async throws {
        let backend = NativeBackend()
        let cleanupEntered = DispatchSemaphore(value: 0)
        let cleanupRelease = DispatchSemaphore(value: 0)
        let firstFinished = DispatchSemaphore(value: 0)
        let secondEntered = DispatchSemaphore(value: 0)
        let secondFinished = DispatchSemaphore(value: 0)
        let cleanups = AtomicCounter()
        let sink = TeardownVideoSink {
            cleanups.increment()
            cleanupEntered.signal()
            cleanupRelease.wait()
        }
        backend.attachVideoSink(sink)
        Thread { backend.stopConnection(); firstFinished.signal() }.start()
        defer { cleanupRelease.signal() }
        try #require(await cleanupEntered.waitAsync(for: .seconds(5)) == .success)
        Thread {
            secondEntered.signal()
            backend.stopConnection()
            secondFinished.signal()
        }.start()
        try #require(await secondEntered.waitAsync(for: .seconds(5)) == .success)
        #expect(await secondFinished.waitAsync(for: .milliseconds(100)) == .timedOut)
        cleanupRelease.signal()
        #expect(await firstFinished.waitAsync(for: .seconds(5)) == .success)
        #expect(await secondFinished.waitAsync(for: .seconds(5)) == .success)
        #expect(cleanups.value == 1)
    }

    @Test func aCleanupCallbackCanReenterStopWithoutRepeatingCleanup() async throws {
        let backend = NativeBackend()
        let cleanups = AtomicCounter()
        let finished = DispatchSemaphore(value: 0)
        let sink = TeardownVideoSink {
            cleanups.increment()
            backend.stopConnection()
        }
        backend.attachVideoSink(sink)
        Thread { backend.stopConnection(); finished.signal() }.start()
        try #require(await finished.waitAsync(for: .seconds(5)) == .success)
        #expect(cleanups.value == 1)
    }
}

private final class TeardownVideoSink: VideoSink {
    private let onSetup: @Sendable () -> Void
    private let onCleanup: @Sendable () -> Void
    init(onSetup: @escaping @Sendable () -> Void = {}, onCleanup: @escaping @Sendable () -> Void) {
        self.onSetup = onSetup
        self.onCleanup = onCleanup
    }
    var capabilities: Int32 { 0 }
    func setup(videoFormat: Int32, width: Int32, height: Int32, redrawRate: Int32) -> Int32 {
        onSetup()
        return 0
    }
    func start() {}
    func stop() {}
    func cleanup() { onCleanup() }
    func submitDecodeUnit(_ unit: DecodeUnit) -> Int32 { StreamProtocol.DR_OK }
}
