// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import GlimmerEngine
import Testing

struct EnginePackageTests {
    @Test func externalConsumerBuildsWireRequest() {
        var request = RtspMessage(command: "OPTIONS", target: "*")
        request.headers = [("CSeq", "1"), ("X-GS-ClientVersion", String(RtspMessage.clientVersion))]
        #expect(String(data: request.serialize(), encoding: .utf8) ==
            "OPTIONS * RTSP/1.0\r\nCSeq: 1\r\nX-GS-ClientVersion: 14\r\n\r\n")
    }

    @Test func requestPreservesHeaderOrder() {
        var request = RtspMessage(command: "OPTIONS", target: "*")
        request.headers = [("CSeq", "2"), ("Z-Last", "first"), ("A-First", "last")]
        #expect(String(data: request.serialize(), encoding: .utf8) ==
            "OPTIONS * RTSP/1.0\r\nCSeq: 2\r\nZ-Last: first\r\nA-First: last\r\n\r\n")
    }

    @Test func requestCanCrossTasks() async {
        let task = Task.detached { RtspMessage(command: "OPTIONS", target: "*") }
        let request = await task.value
        #expect(String(data: request.serialize(), encoding: .utf8) == "OPTIONS * RTSP/1.0\r\n\r\n")
    }
}

private final class ExternalVideoSink: VideoSink {
    let capabilities: Int32 = 0
    func setup(videoFormat: Int32, width: Int32, height: Int32, redrawRate: Int32) -> Int32 { 0 }
    func start() {}
    func stop() {}
    func cleanup() {}
    func submitDecodeUnit(_ unit: DecodeUnit) -> Int32 { 0 }
}

extension EnginePackageTests {
    @Test func externalConsumerConstructsAndStopsTransport() async {
        let connection = StreamConnection(video: ExternalVideoSink()) { _, _ in }
        let first = connection.id
        await connection.stop()
        await connection.stop()
        #expect(connection.id == first)
        let config = StreamConnection.Configuration(width: 1920, height: 1080, fps: 60,
                                                    bitrateKbps: 20_000, videoFormats: [.h264])
        let copied = await Task.detached { config }.value
        _ = copied
    }
}
