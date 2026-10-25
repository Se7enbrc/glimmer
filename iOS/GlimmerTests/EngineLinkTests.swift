// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
@testable import GlimmerEngine
import Synchronization
import Testing
@testable import Glimmer

struct EngineLinkTests {
    @Test @MainActor func publicSessionInvalidStartDisposesPreparedNativeMediaOnce() async {
        let configuration = configuration(width: 0)
        let video = VideoDecoder(configuration: configuration, displayInfo: { nil })
        let audio = AudioDecoder(platform: IOSAudio.platform(environment: {
            StreamSession.audioEnvironment(host: "public-session-test")
        }))
        var quiesces = 0
        var disposals = 0
        let prepared = StreamSession.PreparedMedia(video: video, audio: audio,
            quiesce: { quiesces += 1 }, finalDispose: { disposals += 1 })
        let (session, input) = StreamSession.make(media: prepared, network: unavailableNetwork(),
                                                hostDisposition: .disconnectOnly)
        do {
            try await session.start(appID: 1, configuration: configuration)
            Issue.record("Invalid dimensions must fail before identity or networking.")
        } catch StreamConnection.Failure.invalidConfiguration {
            #expect(quiesces == 1 && disposals == 1)
        } catch {
            Issue.record("Expected the public invalid-configuration failure.")
        }
        await session.stop()
        #expect(disposals == 1)
        #expect(input.registerController(
            ControllerDescriptor(kind: .unknown, supportedButtons: [], capabilities: [])) == nil)
    }

    @Test func buildsRealEngineRequestWithoutNetworking() {
        let engine = EngineLink()
        #expect(engine.protocolVersion == 14)
        #expect(String(data: engine.request, encoding: .utf8) ==
            "OPTIONS * RTSP/1.0\r\nCSeq: 1\r\nX-GS-ClientVersion: 14\r\n\r\n")
    }

    @Test func stoppedConnectionReleasesSinkOnceAndCannotRestart() async {
        let sink = ConnectionTestVideoSink()
        let connection = StreamConnection(video: sink) { _, event in
            if case .input = event { return }
            Issue.record("A connection stopped before startup must not emit transport events.")
        }
        await connection.stop()
        await connection.stop()
        #expect(sink.calls.withLock { $0 } == ["stop", "cleanup"])

        await #expect(throws: CancellationError.self) {
            try await connection.connect(network: unavailableNetwork(), appID: 1, configuration: configuration())
        }
        #expect(sink.calls.withLock { $0 } == ["stop", "cleanup"])
    }

    @Test func invalidConfigurationFailsBeforeIdentityOrNetworking() async {
        let sink = ConnectionTestVideoSink()
        let connection = StreamConnection(video: sink) { _, event in
            if case .input = event { return }
            Issue.record("Invalid configuration must not emit transport events.")
        }
        do {
            try await connection.connect(network: unavailableNetwork(), appID: 1,
                                         configuration: configuration(width: 0))
            Issue.record("Invalid dimensions must fail before connecting.")
        } catch StreamConnection.Failure.invalidConfiguration {
            #expect(sink.calls.withLock { $0.isEmpty })
        } catch {
            Issue.record("Expected the public invalid-configuration failure.")
        }
        await connection.stop()
        #expect(sink.calls.withLock { $0 } == ["stop", "cleanup"])
    }

    private func configuration(width: Int = 1280) -> StreamConnection.Configuration {
        StreamConnection.Configuration(width: width, height: 720, fps: 60, bitrateKbps: 10000,
                                       videoFormats: .h264, audio: .stereo)
    }

    private func unavailableNetwork() -> NetworkClient {
        let identity = IdentityManager(defaultsSuite: nil,
                                       supportBase: FileManager.default.temporaryDirectory) {
            Issue.record("Rejected connection attempts must not load identity storage.")
            return false
        }
        let server = ServerInfo(address: "127.0.0.1", uniqueId: "test-pc", serverName: "Test PC")
        return NetworkClient(server: server, identity: identity, deviceName: "Test iPhone")
    }
}

final class ConnectionTestVideoSink: VideoSink {
    let calls = Mutex<[String]>([])
    let capabilities: Int32 = 0

    func secondsSinceDecodeGateLifted() -> Double { 0 }

    func setup(videoFormat: Int32, width: Int32, height: Int32, redrawRate: Int32) -> Int32 {
        Issue.record("Rejected connection attempts must not set up video.")
        return -1
    }

    func start() { Issue.record("Rejected connection attempts must not start video.") }
    func stop() { calls.withLock { $0.append("stop") } }
    func cleanup() { calls.withLock { $0.append("cleanup") } }

    func submitDecodeUnit(_ unit: DecodeUnit) -> Int32 {
        Issue.record("Rejected connection attempts must not deliver video.")
        return -1
    }
}

@MainActor
struct VideoDecodeEnergyTests {
    @Test(arguments: [true, false])
    func gatedFramesDoNotAssemblePictureData(isIDR: Bool) {
        let decoder = VideoDecoder()
        defer { decoder.teardown() }
        decoder.presentSuppressedLock.withLock { decoder._decodeGated = true }
        var assemblies = 0
        func picture() -> Data {
            assemblies += 1
            return Data([0, 0, 0, 1, 0x41])
        }
        let result = decoder.decodeAssembledFrame(pictureData: picture(), newSps: nil, newPps: nil,
            newVps: nil, isIDR: isIDR, rtpTimestamp: 0, totalLength: 5)
        #expect(result == StreamProtocol.DR_OK)
        #expect(assemblies == 0)
        #expect(decoder.inFlightDecodeBacklog() == 0)
    }

    @Test func admittedUnitPreservesPictureOrderAndParameterSets() throws {
        let decoder = VideoDecoder()
        decoder.isStreaming = true
        decoder.decodeQueue.suspend()
        defer {
            decoder.decodeQueue.resume()
            decoder.teardown()
        }
        let unit = DecodeUnit(frameNumber: 1, frameType: StreamProtocol.FRAME_TYPE_IDR, fullLength: 6,
            frameHostProcessingLatency: 0, receiveTimeUs: 0, enqueueTimeUs: 0, presentationTimeUs: 0,
            rtpTimestamp: 90, hdrActive: false, colorspace: 0, buffers: [
                DecodeBuffer(kind: .sps, data: Data([7])), DecodeBuffer(kind: .picData, data: Data([1, 2])),
                DecodeBuffer(kind: .pps, data: Data([8])), DecodeBuffer(kind: .picData, data: Data([3, 4]))
            ])
        #expect(decoder.submitDecodeUnit(unit) == StreamProtocol.DR_OK)
        let pending = try #require(decoder.pendingDecodes.first)
        #expect(pending.pictureData == Data([1, 2, 3, 4]))
        #expect(pending.newSps == Data([7]))
        #expect(pending.newPps == Data([8]))
        #expect(pending.epoch == 1)
        #expect(decoder.pendingDecodes.count == 1)
    }

    @Test func resyncDoesNotAssembleRejectedPictureData() {
        let decoder = VideoDecoder()
        defer { decoder.teardown() }
        #expect(decoder.armResyncAfterDecodeError(epoch: 0))
        var assemblies = 0
        func picture() -> Data {
            assemblies += 1
            return Data([0, 0, 0, 1, 0x41])
        }
        let result = decoder.decodeAssembledFrame(pictureData: picture(), newSps: nil, newPps: nil,
            newVps: nil, isIDR: false, rtpTimestamp: 0, totalLength: 5)
        #expect(result == StreamProtocol.DR_NEED_IDR)
        #expect(assemblies == 0)
        #expect(decoder.inFlightDecodeBacklog() == 0)
    }
}
