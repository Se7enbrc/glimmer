// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI
import Testing
import UIKit
@testable import Glimmer

extension NativeUIRenderTests {
    @Test(arguments: [false, true])
    func fixtureKeepsRequestedOrientation(portrait: Bool) async throws {
        try await record(Color.gray, name: "fixture-orientation-\(portrait)", size: nil,
                         dark: false, portrait: portrait, inspect: { view in
            let root = try #require(view.window?.rootViewController)
            let requested: UIInterfaceOrientationMask = portrait ? .portrait : .landscapeLeft
            let expected = view.traitCollection.userInterfaceIdiom == .pad ? .all : requested
            #expect(root.supportedInterfaceOrientations == expected)
        })
    }

    @Test(arguments: [false, true], [DynamicTypeSize.large, .accessibility5])
    func iPhoneMenuInventory(portrait: Bool, textSize: DynamicTypeSize) async throws {
        for dark in [false, true] {
            try await recordMenuInventory(portrait: portrait, dark: dark, textSize: textSize)
        }
    }

    private func recordMenuInventory(portrait: Bool, dark: Bool, textSize: DynamicTypeSize) async throws {
        let name = "\(portrait ? "portrait" : "landscape")-\(dark ? "dark" : "light")-"
            + "\(textSize.isAccessibilitySize ? "ax5" : "default")"
        let empty = inventoryModel(pcCount: 0, appCount: 0)
        try await record(LauncherView(model: empty), name: "empty-\(name)", size: nil,
                         dark: dark, textSize: textSize, portrait: portrait)
        for (pcs, apps) in [(1, 1), (6, 12)] {
            let model = inventoryModel(pcCount: pcs, appCount: apps)
            model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
            model.selectInitialPCIfNeeded()
            if let first = model.savedPCs.first { model.select(first) }
            await model.waitUntilOperationFinishes()
            #expect(model.apps.count == apps)
            try await record(LauncherView(model: model, style: .buttons),
                             name: "buttons-\(pcs)pc-\(name)", size: nil,
                             dark: dark, textSize: textSize, portrait: portrait)
            if apps > 1 {
                try await record(LauncherView(model: model, style: .covers), name: "covers-\(name)", size: nil,
                                 dark: dark, textSize: textSize, portrait: portrait)
                let settings = GlimmerSettings(profile: .constant(.native120), stick: .constant(.right), model: model)
                try await record(settings, name: "settings-root-\(name)", size: nil,
                                 dark: dark, textSize: textSize, portrait: portrait)
                for page in GlimmerSettings.Page.allCases {
                    try await record(NavigationStack { settings.settingsPage(page) },
                                     name: "settings-\(page.rawValue)-\(name)", size: nil,
                                     dark: dark, textSize: textSize, portrait: portrait)
                }
            }
        }
        try await record(PairingView(prompt: .init(name: "Living room gaming PC", pin: "1234"), cancel: {}),
                         name: "pin-\(name)", size: nil, dark: dark, textSize: textSize, portrait: portrait)
        try await record(AddPCView(connect: { _ in }), name: "address-\(name)", size: nil,
                         dark: dark, textSize: textSize, portrait: portrait)
        let fixture = LauncherFixture()
        fixture.prepareFailure = LauncherServices.Failure.invalidIdentity
        let failure = fixture.model()
        failure.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        failure.select(fixture.saved)
        await failure.waitUntilOperationFinishes()
        try await record(LauncherView(model: failure), name: "pairing-error-\(name)", size: nil,
                         dark: dark, textSize: textSize, portrait: portrait)
    }

    @Test(arguments: [false, true], [DynamicTypeSize.large, .accessibility5])
    func iPhoneStreamInventory(dark: Bool, textSize: DynamicTypeSize) async throws {
        for state in ["connecting", "streaming", "playing", "waiting", "reconnecting", "ended"] {
            let id = UUID()
            let model = StreamSessionModel(launch: testLaunch(), makePlayback: { _, _, _ in
                StreamPlayback(id: id, events: AsyncStream { _ in }, start: { nil }, stop: {}, screenChanged: {},
                               format: StreamFormat(width: 2622, height: 1206, fps: 120),
                               observeControllers: { $0(true) })
            })
            model.start(surface: StreamSurface())
            if ["streaming", "playing", "waiting"].contains(state) {
                model.receive(.init(sessionID: id, attemptID: UUID(), event: .firstFrame))
                model.receive(.init(sessionID: id, attemptID: UUID(), event: .input(.controllersActive(true))))
                if state == "streaming" { model.showControls() } else { model.resumeInput() }
            }
            if state == "waiting" {
                model.receive(.init(sessionID: id, attemptID: UUID(), event: .waitingForVideo(true)))
            }
            if state == "reconnecting" {
                model.receive(.init(sessionID: id, attemptID: UUID(), event: .reconnecting))
            }
            if state == "ended" { model.stop(); await model.waitUntilStopped() }
            let name = "stream-\(state)-\(dark ? "dark" : "light")-"
                + "\(textSize.isAccessibilitySize ? "ax5" : "default")"
            try await record(ZStack { Color.black.ignoresSafeArea(); StreamControls(model: model, close: {}) },
                             name: name, size: nil, dark: dark, textSize: textSize)
            model.stop()
            await model.waitUntilStopped()
        }
    }

    @Test(arguments: [false, true], [DynamicTypeSize.large, .accessibility5])
    func iPhoneSupplementaryInventory(dark: Bool, textSize: DynamicTypeSize) async throws {
        let name = "right-\(dark ? "dark" : "light")-\(textSize.isAccessibilitySize ? "ax5" : "default")"
        let library = inventoryModel(pcCount: 6, appCount: 12)
        library.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        library.selectInitialPCIfNeeded()
        await library.waitUntilOperationFinishes()
        try await record(LauncherView(model: library), name: "library-\(name)", size: nil,
                         dark: dark, textSize: textSize, landscapeRight: true)
        try await record(PairingView(prompt: .init(name: "Living room gaming PC", pin: "1234"), cancel: {}),
                         name: "pin-\(name)", size: nil, dark: dark, textSize: textSize, landscapeRight: true)
        for state in ["mouse", "mouse-controls", "degraded", "failure"] {
            try await recordSupplementaryStream(state: state, name: name, dark: dark, textSize: textSize)
        }
    }

    private func recordSupplementaryStream(state: String, name: String, dark: Bool,
                                           textSize: DynamicTypeSize) async throws {
        let id = UUID()
        let model = StreamSessionModel(launch: testLaunch(), makePlayback: { _, _, _ in
            StreamPlayback(id: id, events: AsyncStream { _ in }, start: { nil }, stop: {}, screenChanged: {},
                           format: StreamFormat(width: 2622, height: 1206, fps: 120),
                           observeControllers: { $0(true) })
        })
        model.start(surface: StreamSurface())
        model.receive(.init(sessionID: id, attemptID: UUID(), event: .firstFrame))
        model.receive(.init(sessionID: id, attemptID: UUID(), event: .input(.controllersActive(true))))
        if state == "mouse" { model.resumeInput() } else { model.showControls() }
        let connection = StreamConnection(video: ConnectionTestVideoSink()) { _, _ in }
        if state.hasPrefix("mouse") {
            let controller = try #require(connection.input.registerController(
                ControllerDescriptor(kind: .unknown, supportedButtons: [], capabilities: [])))
            model.receive(.init(sessionID: id, attemptID: UUID(), event: .input(.mouseMode(controller, enabled: true))))
        }
        if state == "degraded" {
            model.receive(.init(sessionID: id, attemptID: UUID(), event: .audioFailed("unavailable")))
            model.receive(.init(sessionID: id, attemptID: UUID(), event: .connectionStatus(.poor)))
        }
        if state == "failure" {
            model.receive(.init(sessionID: id, attemptID: UUID(), event: .connectionTerminated(
                errorCode: 0, error: .streamPortsBlocked(proto: "TCP", port: 48010))))
            model.receive(.init(sessionID: id, attemptID: UUID(), event: .stopped))
        }
        try await record(StreamControls(model: model, close: {}), name: "stream-\(state)-\(name)", size: nil,
                         dark: dark, textSize: textSize, landscapeRight: true)
        model.stop()
        await model.waitUntilStopped()
        await connection.stop()
    }

    @Test func accessibleSingleAppRemainsInInitialPhoneViewport() async throws {
        let model = inventoryModel(pcCount: 1, appCount: 1)
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.selectInitialPCIfNeeded()
        await model.waitUntilOperationFinishes()
        #expect(model.apps.count == 1)
        try await record(LauncherView(model: model), name: "single-app-layout",
                         size: CGSize(width: 375, height: 667), dark: false,
                         textSize: .accessibility5, portrait: true, inspect: { view in
            let scroll = try #require(inventoryScrollViews(in: view).first)
            #expect(scroll.contentSize.height <= scroll.bounds.height,
                    "One PC and one app should not require scrolling past a narrow, fragmented header.")
        })
    }

    @Test func endedStatusRemainsScrollableAtMaximumTextSize() async throws {
        let id = UUID()
        let model = StreamSessionModel(launch: testLaunch(), makePlayback: { _, _, _ in
            StreamPlayback(id: id, events: AsyncStream { _ in }, start: { nil }, stop: {}, screenChanged: {},
                           format: StreamFormat(width: 2622, height: 1206, fps: 120))
        })
        model.start(surface: StreamSurface())
        model.stop()
        await model.waitUntilStopped()
        try await record(StreamControls(model: model, close: {}), name: "ended-status-layout", size: nil,
                         dark: true, textSize: .accessibility5, inspect: { view in
            let scrolls = inventoryScrollViews(in: view)
            #expect(!scrolls.isEmpty, "The complete ended message must remain reachable at maximum text size.")
            #expect(scrolls.allSatisfy { $0.bounds.height > 0 })
        })
    }

    private func inventoryScrollViews(in view: UIView) -> [UIScrollView] {
        let own = (view as? UIScrollView).map { [$0] } ?? []
        return own + view.subviews.flatMap { inventoryScrollViews(in: $0) }
    }

    private func inventoryModel(pcCount: Int, appCount: Int) -> LauncherModel {
        let servers = (0..<pcCount).map { index in
            var server = ServerInfo(address: "pc\(index).invalid", uniqueId: "inventory-\(index)",
                                    serverName: index == 0 ? "Living room gaming PC" : "Gaming PC \(index)")
            server.pairStatus = .paired
            return server
        }
        let saved = servers.map { SavedPC(server: $0) }
        let titles = ["Desktop", "Steam Big Picture", "A game with a long title that should remain readable"]
        let apps = (0..<appCount).map { index in
            HostApp(id: index, name: index < titles.count ? titles[index] : "Game \(index + 1)",
                    hdrCapable: false, hidden: false)
        }
        return LauncherModel(calls: .init(savedPCs: { saved },
            prepare: { server, _ in PreparedPC(network: testLaunch().network, server: server) },
            pair: { pc, _ in pc }, apps: { _ in apps }, remember: { _ in saved },
            protectedDataChanged: { _ in }, lastConnectedPCID: { saved.first?.id },
            artwork: { _, _ in Data() }), discoveryEnabled: false)
    }
}
