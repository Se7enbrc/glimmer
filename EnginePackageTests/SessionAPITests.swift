// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AVFoundation
import Foundation
import GlimmerEngine
import Testing

@MainActor
struct SessionAPITests {
    @Test func publicSessionStopDisposesConcreteMediaAndFinishesOrderedEvents() async throws {
        let configuration = StreamConnection.Configuration(width: 1920, height: 1080, fps: 60,
                                                            bitrateKbps: 20_000, videoFormats: .h264)
        let video = VideoDecoder(configuration: configuration, displayInfo: { nil })
        video.attach(to: AVSampleBufferDisplayLayer())
        let audio = AudioDecoder(platform: dormantAudio())
        var lifecycle: [String] = []
        let media = StreamSession.PreparedMedia(video: video, audio: audio,
            quiesce: { lifecycle.append("quiesce") }, finalDispose: { lifecycle.append("disposed") })
        let pair = StreamSession.make(media: media, network: unavailableNetwork(), hostDisposition: .disconnectOnly)
        let events = pair.session.events
        let descriptor = ControllerDescriptor(kind: .unknown, supportedButtons: [.a], capabilities: [])
        _ = try #require(pair.input.registerController(descriptor))
        await pair.session.stop()
        await pair.session.stop()
        #expect(lifecycle == ["quiesce", "disposed"])
        #expect(pair.input.registerController(descriptor) == nil)
        await #expect(throws: CancellationError.self) {
            try await pair.session.start(appID: 1, configuration: configuration)
        }
        var stopped = false
        for await update in events {
            #expect(update.sessionID == pair.session.id)
            #expect(!stopped)
            switch update.event {
            case .input(.controllersActive(false)): break
            case .stopped:
                #expect(lifecycle.last == "disposed")
                stopped = true
            default: Issue.record("A session stopped before start emitted an unexpected event.")
            }
        }
        #expect(stopped)
        #expect(lifecycle == ["quiesce", "disposed"])
    }

    private func unavailableNetwork() -> NetworkClient {
        let identity = IdentityManager(defaultsSuite: nil, supportBase: FileManager.default.temporaryDirectory) {
            Issue.record("Stop before start must not access identity storage.")
            return false
        }
        return NetworkClient(server: ServerInfo(address: "127.0.0.1", uniqueId: "unused", serverName: "Test PC"),
                             identity: identity, deviceName: "External consumer")
    }

    private func dormantAudio() -> AudioPlatform {
        AudioPlatform(makeOutput: { _ in
            Issue.record("Stop before start must not initialize a native output.")
            throw CancellationError()
        }, sampleRoute: { AudioRoute(label: "unused", uid: nil) },
        installRouteListener: { _, _, _ in Issue.record("A stopped session installed a route listener.") },
        removeRouteListener: { _ in },
        installDeviceListeners: { _, _ in Issue.record("A stopped session installed device listeners.") },
        removeDeviceListeners: {},
        captureVolume: { { AudioOutputVolume(volume: nil, muted: nil, routeChanged: false) } },
        environment: { StreamSession.audioEnvironment(host: "unused") })
    }
}
