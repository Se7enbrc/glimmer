// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI
import Testing
import UIKit
@testable import Glimmer

@Suite(.serialized)
@MainActor
struct NativeUIRenderTests {
    @Test(arguments: [false, true])
    func launcherAndPairing(dark: Bool) async throws {
        let launch = testLaunch()
        let server: ServerInfo = {
            var server = ServerInfo(address: "pc.invalid", uniqueId: launch.pcID, serverName: "Living room PC")
            server.pairStatus = .paired
            server.serverCertPEM = "test placeholder, never sent to a transport"
            return server
        }()
        let saved = SavedPC(server: server)
        let apps = [HostApp(id: 1, name: "Desktop", hdrCapable: false, hidden: false),
                    HostApp(id: 2, name: "A game with a long title that should wrap without hiding the launch control",
                            hdrCapable: false, hidden: false),
                    HostApp(id: 3, name: "Racing", hdrCapable: false, hidden: false)]
        var calls = LauncherModel.Calls(savedPCs: { [] },
            prepare: { _, _ in PreparedPC(network: launch.network, server: server) },
            pair: { pc, _ in pc }, apps: { _ in apps }, remember: { _ in [saved] }, protectedDataChanged: { _ in })
        let empty = LauncherModel(calls: calls, discoveryEnabled: false)
        empty.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        let style = dark ? "dark" : "light"
        try await record(LauncherView(model: empty), name: "launcher-empty-\(style)", landscape: false, dark: dark)
        calls.savedPCs = { [saved] }
        let library = LauncherModel(calls: calls, discoveryEnabled: false)
        library.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        library.select(saved)
        await library.waitUntilOperationFinishes()
        #expect(library.apps.count == 3)
        try await record(LauncherView(model: library), name: "launcher-library-\(style)", landscape: false, dark: dark)
        try await record(PairingView(prompt: .init(name: "Living room PC", pin: "1234"), cancel: {}),
                         name: "pairing-\(style)", landscape: false, dark: dark)
    }

    @Test(arguments: ["connecting", "streaming", "ended"])
    func streamControls(state: String) async throws {
        let id = UUID()
        let model = StreamSessionModel(launch: testLaunch(), makePlayback: { _, _, _ in
            StreamPlayback(id: id, connect: {}, stop: {}, teardown: {}, screenChanged: {}, setHDR: { _ in })
        }, readIdleTimer: { false }, writeIdleTimer: { _ in })
        model.start(surface: StreamSurface())
        if state == "streaming" { model.receive(.firstFrame(id)) }
        if state == "ended" { model.stop(); await model.waitUntilStopped() }
        try await record(ZStack { Color.black.ignoresSafeArea(); StreamControls(model: model, close: {}) },
                         name: "stream-\(state)", landscape: true, dark: true)
        model.stop()
        await model.waitUntilStopped()
    }

    private func record<Content: View>(_ content: Content, name: String, landscape: Bool,
                                       dark: Bool) async throws {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.windows.first(where: \.isKeyWindow)
        let window = UIWindow(windowScene: scene)
        let size = landscape ? CGSize(width: 852, height: 393) : CGSize(width: 393, height: 852)
        window.frame = CGRect(origin: .zero, size: size)
        let host = UIHostingController(rootView: content.dynamicTypeSize(.xxxLarge))
        host.overrideUserInterfaceStyle = dark ? .dark : .light
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        host.view.frame = window.bounds
        host.view.setNeedsLayout()
        host.view.layoutIfNeeded()
        // Give SwiftUI one finite layout transaction on the hosted Simulator.
        try await Task.sleep(for: .milliseconds(200))
        let renderer = UIGraphicsImageRenderer(bounds: window.bounds)
        var rendered = false
        let image = renderer.image { _ in
            rendered = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
        }
        #expect(rendered)
        let data = try #require(image.pngData())
        #expect(data.count > 1_000)
        Attachment.record(Array(data), named: "\(name)-large-text.png")
    }
}
