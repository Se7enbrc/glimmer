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
    let leaveGamesRunning: Bool
    let continuing: Bool
    let previousFormat: ContinuationFormat?
    let useScreenSize: Bool
    let startFormat: ContinuationFormat?
    let approvedOccupant: Int?
    var hostDisposition: StreamHostDisposition { .init(leaveGamesRunning: leaveGamesRunning) }

    init(network: NetworkClient, pcID: String, pcName: String, appID: Int, appName: String,
         profile: StreamProfile = .native120, mouseStick: ControllerMouseStick = .right,
         touchMouseEnabled: Bool = true, leaveGamesRunning: Bool = false,
         continuing: Bool = false, previousFormat: ContinuationFormat? = nil,
         useScreenSize: Bool = false, approvedOccupant: Int? = nil, startFormat: ContinuationFormat? = nil) {
        self.network = network
        self.pcID = pcID
        self.pcName = pcName
        self.appID = appID
        self.appName = appName
        self.profile = profile
        self.mouseStick = mouseStick
        self.touchMouseEnabled = touchMouseEnabled
        self.leaveGamesRunning = leaveGamesRunning
        self.continuing = continuing
        self.previousFormat = previousFormat
        self.useScreenSize = useScreenSize
        self.approvedOccupant = approvedOccupant
        self.startFormat = startFormat
    }
}

@MainActor
struct StreamPlayback {
    let id: UUID
    let events: AsyncStream<StreamSession.Update>
    let start: @Sendable () async throws -> Void
    let stop: @Sendable () async -> Void
    let screenChanged: @MainActor () -> Void
    var quit: (@Sendable () async throws -> Void)?
    var input: StreamInput?
    var focusInput: (@MainActor (Bool) -> Void)?
    var format: StreamFormat?
    var setVisible: (@MainActor (Bool, VideoDecoder.PresentationVisibility) -> Void)?
    var observeControllers: (@MainActor (@escaping @MainActor (Bool) -> Void) -> Void)?
    var touchGamepad: TouchGamepadCapture?
    var showTouchControls: (@MainActor (Bool) -> Void)?

    static func make(launch: StreamLaunch, surface: StreamSurface,
                     quiesce: @escaping @MainActor @Sendable () -> Void) throws -> StreamPlayback {
        guard let screen = surface.window?.windowScene?.screen else { throw StreamProfile.Failure.displayUnavailable }
        let pixels = surface.streamPixels
        let native = try launch.useScreenSize
            ? launch.profile.screenSize(windowPixels: pixels, maximumFramesPerSecond: screen.maximumFramesPerSecond)
            : launch.profile.resolve(windowPixels: pixels, maximumFramesPerSecond: screen.maximumFramesPerSecond)
        let format = StreamFormat.continuing(launch, native: native,
                                             maximumFPS: screen.maximumFramesPerSecond)
        let configuration = format.configuration(potentialEDRHeadroom: Double(screen.potentialEDRHeadroom))
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
                                                  hostDisposition: launch.hostDisposition,
            diagnosticsDirectory: DiagnosticsDefaults.directory)
        input.setStopChord(.menuOptionsShoulders)
        input.setControllerMouseMapping(launch.mouseStick.mapping)
        nativeInput.start(input: input, scope: .game(pcID: launch.pcID, appID: UInt32(clamping: launch.appID)))
        return StreamPlayback(id: session.id, events: session.events, start: {
            if launch.continuing {
                await session.requireContinuation(previous: launch.useScreenSize ? launch.previousFormat : nil)
            }
            if let occupant = launch.approvedOccupant { await session.approveReplacement(of: occupant) }
            try await session.start(appID: launch.appID, configuration: configuration)
        }, stop: { await session.stop() }, screenChanged: { video.pacingScreenDidChange() },
           quit: {
               await session.disconnectLeavingGameRunning()
               try await StreamSession.quitRunningApp(network: launch.network, expectedAppID: launch.appID)
           }, input: input, focusInput: nativeInput.focus, format: format,
           setVisible: { visible, inputs in
               video.setPresentSuppressed(!visible, visibility: inputs, sessionGeneration: session.id)
               Task { await session.setBitrateChangesAvailable(visible) }
           }, observeControllers: nativeInput.observeControllers, touchGamepad: nativeInput.touch,
           showTouchControls: nativeInput.showTouchControls)
    }
}
