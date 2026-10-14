// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import GlimmerEngine
import Synchronization
import Testing
@testable import Glimmer

struct EngineLinkTests {
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
