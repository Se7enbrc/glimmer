// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

#if DEBUG
import GlimmerEngine
import Foundation
import GameController
import UIKit

@MainActor
enum UITestLauncher {
    static func make() -> LauncherModel? {
        let environment = ProcessInfo.processInfo.environment
        guard PersistentStorage.isTesting else {
            return nil
        }
        let running = environment["GLIMMER_UI_TESTING"] == "running"
        let controller = environment["GLIMMER_UI_TESTING"] == "stream-controller"
        let streaming = environment["GLIMMER_UI_TESTING"] == "stream" || controller
        if streaming {
            for (key, chord) in [("quitHotkey", HotkeyChord.defaultQuit), ("statsHotkey", .defaultStats)] {
                PersistentStorage.defaults.set(try? JSONEncoder().encode(chord), forKey: key)
            }
            PersistentStorage.defaults.set(false, forKey: "showStreamStats")
        }
        let count = running ? 3 : environment["GLIMMER_UI_TESTING"] == "one" || streaming ? 1
            : environment["GLIMMER_UI_TESTING"] == "many" ? 12 : 0
        let pcs = (0..<count).map { index in
            var server = ServerInfo(address: "pc.invalid", uniqueId: "fixture-\(index)",
                                    serverName: "Living room gaming PC \(index + 1)")
            server.pairStatus = .paired
            if running { server.currentGameID = 1 }
            return SavedPC(server: server)
        }
        let identity = IdentityManager(defaultsSuite: "io.ugfugl.Glimmer.ui-tests.unused",
                                       supportBase: FileManager.default.temporaryDirectory,
                                       protectedDataAvailable: { false })
        let gameTitle = running ? "SuperTuxKart" : "A game with a long title that needs room to wrap"
        let titles = ["Desktop", "Steam Big Picture", gameTitle, "Racing"]
        let apps = (0..<count).map { index in
            HostApp(id: index + (running ? 1 : 0), name: titles[index % titles.count], hdrCapable: false, hidden: false)
        }
        // UI automation must never discover or connect to the user's PCs.
        let calls = LauncherModel.Calls(savedPCs: { pcs }, prepare: { server, _ in
            var current = server
            if running { current.currentGameID = 1 }
            return PreparedPC(network: NetworkClient(server: current, identity: identity, deviceName: "Test device"),
                              server: current)
        }, pair: { pc, _ in pc }, apps: { _ in apps }, remember: { _ in pcs }, protectedDataChanged: { _ in },
           lastConnectedPCID: { pcs.first?.id }, artwork: { _, _ in Data() }, makeSession: { launch in
            StreamSessionModel(launch: launch, makePlayback: { launch, surface, _ in
                guard streaming else { throw CancellationError() }
                return try playback(launch: launch, surface: surface, controller: controller)
            })
        })
        return LauncherModel(calls: calls, discoveryEnabled: false)
    }

    private static func playback(launch: StreamLaunch, surface: StreamSurface,
                                 controller: Bool) throws -> StreamPlayback {
        let state = ProcessInfo.processInfo.environment["GLIMMER_OVERLAY_STATE"]
        if state == "failure" { throw URLError(.cannotConnectToHost) }
        let format = try launch.profile.resolve(surface: surface)
        let decoder = VideoDecoder(configuration: format.configuration(potentialEDRHeadroom: 1), displayInfo: { nil })
        let connection = StreamConnection(video: decoder) { _, _ in }
        let controllers = IOSControllerCapture(calls: .init(register: connection.input.registerController,
            unregister: connection.input.unregisterController, submit: connection.input.submitController,
            focus: { _ in }), center: NotificationCenter(),
            readControllers: { controller ? [GCController.withExtendedGamepad()] : [] })
        let native = NativeInputLifetime()
        native.start(input: connection.input, controllers: controllers)
        let bright = ProcessInfo.processInfo.environment["GLIMMER_OVERLAY_PICTURE"] == "light"
        surface.displayLayer.backgroundColor = (bright ? UIColor(white: 0.94, alpha: 1) : .black).cgColor
        let stats = StreamStats(surface: surface, snapshot: {
            var snapshot = StreamStatsSnapshot()
            snapshot.renderedFps = 59.9
            snapshot.rttMs = 5.9
            snapshot.measuredBitrateMbps = 45.2
            snapshot.videoCodec = "HEVC"
            return snapshot
        }, collection: { _ in }, videoSize: { surface.bounds.size }, backdrop: { _ in bright ? 0.85 : 0.01 })
        let id = UUID()
        let events = AsyncStream<StreamSession.Update>.makeStream()
        return StreamPlayback(id: id, events: events.stream, start: {
            if state != "connecting" {
                events.continuation.yield(.init(sessionID: id, attemptID: UUID(), event: .firstFrame))
            }
            if state == "reconnecting" || state == "waiting" {
                events.continuation.yield(.init(sessionID: id, attemptID: UUID(),
                    event: state == "waiting" ? .waitingForVideo(true) : .reconnecting))
            }
            return nil
        }, stop: {
            await MainActor.run {
                stats.setChromeVisible(false)
                stats.setVisible(false)
                native.stop()
            }
            await connection.stop()
            events.continuation.finish()
        }, screenChanged: {}, input: connection.input, focusInput: native.focus,
           format: format, observeControllers: native.observeControllers,
           touchGamepad: native.touch, showTouchControls: native.showTouchControls,
           showStats: stats.setVisible, showOverlayChrome: stats.setChromeVisible)
    }
}
#endif
