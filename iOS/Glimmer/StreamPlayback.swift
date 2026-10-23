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
    let profile: StreamProfile
    let mouseStick: ControllerMouseStick
    let touchMouseEnabled: Bool

    init(network: NetworkClient, pcID: String, pcName: String, appID: Int, appName: String,
         profile: StreamProfile = .native120, mouseStick: ControllerMouseStick = .right,
         touchMouseEnabled: Bool = true) {
        self.network = network
        self.pcID = pcID
        self.pcName = pcName
        self.appID = appID
        self.appName = appName
        self.profile = profile
        self.mouseStick = mouseStick
        self.touchMouseEnabled = touchMouseEnabled
    }
}

@MainActor
struct StreamPlayback {
    let id: UUID
    let events: AsyncStream<StreamSession.Update>
    let start: @Sendable () async throws -> Void
    let stop: @Sendable () async -> Void
    let screenChanged: @MainActor () -> Void
    var input: StreamInput?
    var focusInput: (@MainActor (Bool) -> Void)?
    var format: StreamFormat?
    var setVisible: (@MainActor (Bool) -> Void)?
    var observeControllers: (@MainActor (@escaping @MainActor (Bool) -> Void) -> Void)?

    static func make(launch: StreamLaunch, surface: StreamSurface,
                     quiesce: @escaping @MainActor @Sendable () -> Void) throws -> StreamPlayback {
        guard let screen = surface.window?.windowScene?.screen else { throw StreamProfile.Failure.displayUnavailable }
        let format = try launch.profile.resolve(nativePixels: screen.nativeBounds.size,
                                                maximumFramesPerSecond: screen.maximumFramesPerSecond)
        let configuration = format.configuration
        let video = VideoDecoder(configuration: configuration, displayInfo: { [weak surface] in
            guard let screen = surface?.window?.windowScene?.screen else { return nil }
            return VideoDisplayInfo(currentHeadroom: Double(screen.currentEDRHeadroom),
                potentialHeadroom: Double(screen.potentialEDRHeadroom), name: "Display",
                maximumFramesPerSecond: screen.maximumFramesPerSecond)
        })
        let pcID = launch.pcID
        let audio = AudioDecoder(platform: IOSAudio.platform(environment: {
            StreamSession.audioEnvironment(host: pcID)
        }))
        video.rebuildDisplayLayerHook = { [weak surface, weak video] in
            guard let video else { return nil }
            return surface?.replaceDisplayLayer { video.attach(to: $0) }
        }
        video.attach(to: surface.displayLayer)
        video.startPacing(display: surface.pacerDisplay, configuredFps: format.pacingFPS)
        let nativeInput = NativeInputLifetime()
        let media = StreamSession.PreparedMedia(video: video, audio: audio,
            quiesce: { nativeInput.focus(false); quiesce() }, finalDispose: { nativeInput.stop() })
        let (session, input) = StreamSession.make(media: media, network: launch.network,
                                                  hostDisposition: .disconnectOnly,
            diagnosticsDirectory: URL.applicationSupportDirectory
                .appendingPathComponent("Diagnostics", isDirectory: true))
        input.setStopChord(.menuOptionsShoulders)
        input.setControllerMouseMapping(launch.mouseStick.mapping)
        nativeInput.controllers = IOSControllerCapture(input: input)
        nativeInput.controllers?.start()
        return StreamPlayback(id: session.id, events: session.events, start: {
            try await session.start(appID: launch.appID, configuration: configuration)
        }, stop: { await session.stop() }, screenChanged: { video.pacingScreenDidChange() },
           input: input, focusInput: nativeInput.focus, format: format,
           setVisible: { video.setPresentSuppressed(!$0) }, observeControllers: nativeInput.observeControllers)
    }
}

/// The session retains native capture across recovery and releases it after shared media teardown.
@MainActor
private final class NativeInputLifetime {
    var controllers: IOSControllerCapture?
    func focus(_ focused: Bool) { controllers?.setFocused(focused) }
    func observeControllers(_ changed: @escaping @MainActor (Bool) -> Void) {
        controllers?.observeConnections(changed)
    }
    func stop() { controllers?.stop(); controllers = nil }
}
