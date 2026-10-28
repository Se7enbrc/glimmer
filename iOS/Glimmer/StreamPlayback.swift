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
    let touchMouseEnabled: Bool
    let leaveGamesRunning: Bool
    let continuing: Bool
    let previousFormat: ContinuationFormat?
    let useScreenSize: Bool
    let startFormat: ContinuationFormat?
    let approvedOccupant: Int?
    var hostDisposition: StreamHostDisposition { .init(leaveGamesRunning: leaveGamesRunning) }

    init(network: NetworkClient, pcID: String, pcName: String, appID: Int, appName: String,
         profile: StreamProfile = .native120,
         touchMouseEnabled: Bool = true, leaveGamesRunning: Bool = false,
         continuing: Bool = false, previousFormat: ContinuationFormat? = nil,
         useScreenSize: Bool = false, approvedOccupant: Int? = nil, startFormat: ContinuationFormat? = nil) {
        self.network = network
        self.pcID = pcID
        self.pcName = pcName
        self.appID = appID
        self.appName = appName
        self.profile = profile
        self.touchMouseEnabled = touchMouseEnabled
        self.leaveGamesRunning = leaveGamesRunning
        self.continuing = continuing
        self.previousFormat = previousFormat
        self.useScreenSize = useScreenSize
        self.approvedOccupant = approvedOccupant
        self.startFormat = startFormat
    }
}

/// What a started stream actually asked the PC for: the listed mode and, when adaptive, its first rate.
struct StreamStart: Equatable, Sendable {
    let format: StreamFormat
    let startKbps: Int?
}

@MainActor
struct StreamPlayback {
    let id: UUID
    let events: AsyncStream<StreamSession.Update>
    let start: @Sendable () async throws -> StreamStart?
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
    /// Moves a running stream to a new listed size through the resume-only seam; the game keeps running.
    var requestFormatChange: StreamWindowResize.Request?
    var showStats: (@MainActor (Bool) -> Void)?
    var showOverlayChrome: (@MainActor (Bool) -> Void)?

    static func configureInput(_ input: StreamInput, defaults: UserDefaults = PersistentStorage.defaults) {
        input.setStopChord(.menuOptionsShoulders)
        input.setControllerMenuOpensControls(true)
        input.setControllerMouseBindings(.load(from: defaults))
    }

    static func make(launch: StreamLaunch, surface: StreamSurface,
                     quiesce: @escaping @MainActor @Sendable () -> Void) throws -> StreamPlayback {
        guard let screen = surface.window?.windowScene?.screen else { throw StreamProfile.Failure.displayUnavailable }
        let pixels = surface.streamPixels
        let native = try launch.profile.resolve(surface: surface, useScreenSize: launch.useScreenSize)
        let format = StreamFormat.continuing(launch, native: native,
                                             maximumFPS: screen.maximumFramesPerSecond)
        let formats = try StreamFormats(full: format, windowPixels: pixels,
                                        maximumFramesPerSecond: screen.maximumFramesPerSecond)
        let headroom = Double(screen.potentialEDRHeadroom)
        let configuration = format.configuration(potentialEDRHeadroom: headroom)
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
        let stats = StreamStats(surface: surface, snapshot: { video.overlaySnapshot() },
            collection: { video.statsOverlayEnabled = $0 }, videoSize: { video.overlayVideoSize },
            backdrop: { video.hudBackdropRect = $0; return video.hudBackdropLuminance },
            chromeSampling: { video.overlayChromeEnabled = $0 }, observeBackdrop: { video.observeBackdrop($0) })
        let nativeInput = NativeInputLifetime()
        let adaptive = AdaptiveBandwidth.isEnabled()
        let bandwidth = BandwidthSignals()
        let media = StreamSession.PreparedMedia(video: video, audio: audio,
            quiesce: { nativeInput.focus(false); quiesce() },
            finalDispose: {
                stats.setChromeVisible(false)
                stats.setVisible(false)
                nativeInput.stop()
                bandwidth.stop()
            })
        let (session, input) = StreamSession.make(media: media, network: launch.network,
                                                  hostDisposition: launch.hostDisposition,
            bandwidthInputs: bandwidth.inputs, adaptiveBandwidth: adaptive)
        configureInput(input)
        nativeInput.start(input: input, scope: .game(pcID: launch.pcID, appID: UInt32(clamping: launch.appID)))
        return StreamPlayback(id: session.id, events: session.events, start: {
            if launch.continuing {
                await session.requireContinuation(previous: launch.useScreenSize ? launch.previousFormat : nil)
            }
            if let occupant = launch.approvedOccupant { await session.approveReplacement(of: occupant) }
            let address = await launch.network.destinationAddress()
            try Task.checkCancellation()
            await bandwidth.start(host: address)
            // Low Data Mode starts at the reduced listed mode; the session moves sizes on later edges.
            if adaptive { await bandwidth.waitForPath() }
            // A continued game keeps its known size, so it never trades sizes for Low Data Mode.
            let sized = adaptive && !launch.continuing
            let started = formats.start(lowData: sized && bandwidth.inputs.snapshot().path.constrained == true)
            await MainActor.run { video.startPacing(display: surface.pacerDisplay, configuredFps: started.pacingFPS) }
            do {
                try await session.start(appID: launch.appID,
                                        configuration: started.configuration(potentialEDRHeadroom: headroom,
                                                                            sizes: sized ? formats.sizes : nil))
                // Fixed quality needs launch-time route facts, but no path observation during play.
                if !adaptive { await bandwidth.stop() }
                return StreamStart(format: started, startKbps: await session.adaptiveStartKbps)
            } catch {
                await bandwidth.stop()
                throw error
            }
        }, stop: { await session.stop() }, screenChanged: { video.pacingScreenDidChange() },
           quit: {
               await session.disconnectLeavingGameRunning()
               try await StreamSession.quitRunningApp(network: launch.network, expectedAppID: launch.appID)
           }, input: input, focusInput: nativeInput.focus, format: format,
           setVisible: { visible, inputs in
               video.setPresentSuppressed(!visible, visibility: inputs, sessionGeneration: session.id)
               if adaptive || !visible { bandwidth.setForeground(visible) }
               Task { await session.setBitrateChangesAvailable(visible) }
           }, observeControllers: nativeInput.observeControllers, touchGamepad: nativeInput.touch,
           showTouchControls: nativeInput.showTouchControls,
           requestFormatChange: { await StreamWindowResize.request($0, session: session) }, showStats: stats.setVisible,
           showOverlayChrome: stats.setChromeVisible)
    }
}
