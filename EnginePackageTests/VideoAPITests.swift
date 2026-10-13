// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AVFoundation
import GlimmerEngine
import Testing

@MainActor
struct VideoAPITests {
    @Test func publicDecoderAttachesAndStopsWithoutNetworking() async {
        let configuration = StreamConnection.Configuration(width: 1920, height: 1080, fps: 60,
                                                            bitrateKbps: 20_000, videoFormats: .h264)
        let decoder = VideoDecoder(configuration: configuration, displayInfo: { nil })
        let layer = AVSampleBufferDisplayLayer()
        decoder.attach(to: layer)
        let display = PacerDisplay(makeLink: { _, _ in nil }, screen: {
            PacerScreen(identity: "detached", maximumHz: 0, minimumHz: nil, scale: 1)
        }, tickOffMain: { false }, prepareTickThread: {})
        decoder.startPacing(display: display, configuredFps: 60)
        let connection = StreamConnection(video: decoder, onEvent: { _, _ in })
        await connection.stop()
        decoder.teardown()
        #expect(!decoder.isHDRActive)
    }
}
