// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AVFoundation
import GlimmerEngine
import UIKit

struct StreamLaunch: Identifiable, Sendable {
    let id = UUID()
    let network: NetworkClient
    let pcID: String
    let pcName: String
    let appID: Int
    let appName: String
}

enum StreamBaseline {
    static let width = 1920
    static let height = 1080
    static let fps = 60
    static let bitrateKbps = 20_000

    static var configuration: StreamConnection.Configuration {
        StreamConnection.Configuration(width: width, height: height, fps: fps, bitrateKbps: bitrateKbps,
                                       videoFormats: .h264, audio: .stereo)
    }
}

@MainActor
struct StreamPlayback {
    enum Event: Sendable {
        case connection(UUID, StreamConnection.Event)
        case firstFrame(UUID)
    }

    let id: UUID
    let connect: @Sendable () async throws -> Void
    let stop: @Sendable () async -> Void
    let teardown: @MainActor () -> Void
    let screenChanged: @MainActor () -> Void
    let setHDR: @MainActor (Bool) -> Void
    var input: StreamInput?
    var focusInput: (@MainActor (Bool) -> Void)?
    var stopInput: (@MainActor () -> Void)?

    static func make(launch: StreamLaunch, surface: StreamSurface,
                     events: AsyncStream<Event>.Continuation) -> StreamPlayback {
        let configuration = StreamBaseline.configuration
        let video = VideoDecoder(configuration: configuration, displayInfo: { [weak surface] in
            guard let screen = surface?.window?.windowScene?.screen else { return nil }
            return VideoDisplayInfo(currentHeadroom: Double(screen.currentEDRHeadroom),
                potentialHeadroom: Double(screen.potentialEDRHeadroom), name: "Display",
                maximumFramesPerSecond: screen.maximumFramesPerSecond)
        })
        let pcID = launch.pcID
        let audio = AudioDecoder(platform: IOSAudio.platform(environment: {
            AudioEnvironment(host: pcID, link: "unknown", jitterMs: .nan)
        }))
        let connection = StreamConnection(video: video, audio: audio) { id, event in
            events.yield(.connection(id, event))
        }
        let controllers = IOSControllerCapture(input: connection.input)
        connection.input.setStopChord(.menuOptionsShoulders)
        controllers.start()
        let id = connection.id
        video.onFirstDecodedFrame = { events.yield(.firstFrame(id)) }
        video.rebuildDisplayLayerHook = { [weak surface, weak video] in
            guard let video else { return nil }
            return surface?.replaceDisplayLayer { video.attach(to: $0) }
        }
        video.attach(to: surface.displayLayer)
        video.startPacing(display: surface.pacerDisplay, configuredFps: Int32(StreamBaseline.fps))
        return StreamPlayback(id: id, connect: {
            try await connection.connect(network: launch.network, appID: launch.appID, configuration: configuration)
        }, stop: { await connection.stop() }, teardown: {
            video.teardown()
            audio.shutdown()
        }, screenChanged: { video.pacingScreenDidChange() }, setHDR: { video.setHDR(enabled: $0) },
           input: connection.input, focusInput: controllers.setFocused, stopInput: controllers.stop)
    }
}
