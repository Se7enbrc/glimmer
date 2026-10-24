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
        let count = environment["GLIMMER_UI_TESTING"] == "one" ? 1
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
            StreamSessionModel(launch: launch, makePlayback: { _, _, _ in throw CancellationError() })
        })
        return LauncherModel(calls: calls, discoveryEnabled: false)
    }
}
#endif
