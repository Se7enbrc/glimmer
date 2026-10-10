//
//  BackendGlueTests.swift
//
//  The glue between the native engine and the session: connection events
//  reaching the bridge's stream, the bridge pointer, RTSP URL parsing and the
//  protocol's default async connect.
//

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
        let session = StreamSession(backend: InputRecordingBackend())
        let bridge = StreamBridgeContext(
            session: session, videoDecoder: VideoDecoder(), audioDecoder: AudioDecoder(),
            inputForwarder: InputForwarder())
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
            session: StreamSession(backend: InputRecordingBackend()), videoDecoder: VideoDecoder(),
            audioDecoder: AudioDecoder(), inputForwarder: InputForwarder())
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
