// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

#if DEBUG
import GlimmerEngine
import Foundation

@MainActor
enum UITestLauncher {
    static func make() -> LauncherModel? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["GLIMMER_UI_TESTING"] != nil || environment["XCTestConfigurationFilePath"] != nil else {
            return nil
        }
        let streaming = environment["GLIMMER_UI_TESTING"] == "stream"
        if streaming {
            for (key, chord) in [("quitHotkey", HotkeyChord.defaultQuit), ("statsHotkey", .defaultStats)] {
                UserDefaults.standard.set(try? JSONEncoder().encode(chord), forKey: key)
            }
            UserDefaults.standard.set(false, forKey: "showStreamStats")
        }
        let count = environment["GLIMMER_UI_TESTING"] == "one" || streaming ? 1
            : environment["GLIMMER_UI_TESTING"] == "many" ? 12 : 0
        let pcs = (0..<count).map { index in
            var server = ServerInfo(address: "pc.invalid", uniqueId: "fixture-\(index)",
                                    serverName: "Living room gaming PC \(index + 1)")
            server.pairStatus = .paired
            return SavedPC(server: server)
        }
        let identity = IdentityManager(defaultsSuite: "io.ugfugl.Glimmer.ui-tests.unused",
                                       supportBase: FileManager.default.temporaryDirectory,
                                       protectedDataAvailable: { false })
        let titles = ["Desktop", "Steam Big Picture", "A game with a long title that needs room to wrap", "Racing"]
        let apps = (0..<count).map { index in
            HostApp(id: index, name: titles[index % titles.count], hdrCapable: false, hidden: false)
        }
        // UI automation must never discover or connect to the user's PCs.
        let calls = LauncherModel.Calls(savedPCs: { pcs }, prepare: { server, _ in
            PreparedPC(network: NetworkClient(server: server, identity: identity, deviceName: "Test device"),
                       server: server)
        }, pair: { pc, _ in pc }, apps: { _ in apps }, remember: { _ in pcs }, protectedDataChanged: { _ in },
           lastConnectedPCID: { pcs.first?.id }, artwork: { _, _ in Data() }, makeSession: { launch in
            StreamSessionModel(launch: launch, makePlayback: { launch, surface, _ in
                guard streaming else { throw CancellationError() }
                let stats = StreamStats(surface: surface, snapshot: {
                    var snapshot = StreamStatsSnapshot()
                    snapshot.hostFps = 59.9
                    snapshot.rttMs = 5.9
                    snapshot.measuredBitrateMbps = 45.2
                    snapshot.videoCodec = "HEVC"
                    return snapshot
                }, collection: { _ in }, videoSize: { surface.bounds.size }, backdrop: { _ in nil })
                let id = UUID()
                let events = AsyncStream<StreamSession.Update>.makeStream()
                return StreamPlayback(id: id, events: events.stream, start: {
                    events.continuation.yield(.init(sessionID: id, attemptID: UUID(), event: .firstFrame))
                    return nil
                }, stop: {
                    await MainActor.run { stats.setVisible(false) }
                    events.continuation.finish()
                }, screenChanged: {},
                   format: try launch.profile.resolve(surface: surface), showStats: stats.setVisible)
            })
        })
        return LauncherModel(calls: calls, discoveryEnabled: false)
    }
}
#endif
