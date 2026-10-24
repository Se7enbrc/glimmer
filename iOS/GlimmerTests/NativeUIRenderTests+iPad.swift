// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI
import Testing
import UIKit
@testable import Glimmer

extension NativeUIRenderTests {
    @Test func steamSymbolSupportsLargestText() throws {
        for scale in [Image.Scale.small, .medium, .large] {
            let renderer = ImageRenderer(content: AppGlyph(name: "Steam").font(.body)
                .imageScale(scale).dynamicTypeSize(.accessibility5).foregroundStyle(.white)
                .frame(width: 100, height: 100))
            let image = try #require(renderer.cgImage)
            var pixels = [UInt8](repeating: 0, count: 100 * 100 * 4)
            let hasInk = try pixels.withUnsafeMutableBytes { bytes in
                let context = try #require(CGContext(data: bytes.baseAddress, width: 100, height: 100,
                    bitsPerComponent: 8, bytesPerRow: 400, space: CGColorSpaceCreateDeviceRGB(),
                    bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue))
                context.draw(image, in: CGRect(x: 0, y: 0, width: 100, height: 100))
                return stride(from: 3, to: bytes.count, by: 4).contains { bytes[$0] != 0 }
            }
            #expect(hasInk, "The Steam glyph must remain visible at the largest accessibility text size.")
        }
    }

    @Test(arguments: ["portrait", "landscape", "narrow", "medium"], [false, true])
    func iPadInventory(layout: String, dark: Bool) async throws {
        let size = try iPadViewport(layout: layout)
        for textSize in [DynamicTypeSize.large, .accessibility5] {
            let label = "ipad-\(layout)-\(dark ? "dark" : "light")-\(textSize == .large ? "default" : "ax5")"
            try await iPadLauncherInventory(label: label, size: size, dark: dark, textSize: textSize)
            try await iPadStreamInventory(label: label, size: size, textSize: textSize)
        }
    }

    @Test(arguments: ["portrait", "landscape", "narrow", "medium"], [false, true])
    func iPadSettingsInventory(layout: String, dark: Bool) async throws {
        let size = try iPadViewport(layout: layout)
        let model = iPadLibrary(count: 12)
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        for textSize in [DynamicTypeSize.large, .accessibility5] {
            let label = "ipad-\(layout)-\(dark ? "dark" : "light")-\(textSize == .large ? "default" : "ax5")"
            let settings = GlimmerSettings(profile: .constant(.native120), stick: .constant(.right), model: model)
            try await record(settings, name: "\(label)-settings", size: size, dark: dark, textSize: textSize)
            for page in GlimmerSettings.Page.allCases {
                try await record(NavigationStack { settings.settingsPage(page) },
                                 name: "\(label)-settings-\(page.rawValue)",
                                 size: size, dark: dark, textSize: textSize)
            }
        }
    }

    @Test(arguments: ["portrait", "landscape", "narrow", "medium"], [false, true])
    func iPadLabelInventory(layout: String, dark: Bool) async throws {
        let size = try iPadViewport(layout: layout)
        for textSize in [DynamicTypeSize.large, .accessibility5] {
            let label = "ipad-\(layout)-\(dark ? "dark" : "light")-\(textSize == .large ? "default" : "ax5")"
            try await iPadLauncherInventory(label: label, size: size, dark: dark, textSize: textSize)
            let model = iPadLibrary(count: 12)
            try await record(GlimmerSettings(profile: .constant(.native120), stick: .constant(.right), model: model),
                             name: "\(label)-settings", size: size, dark: dark, textSize: textSize)
        }
    }

    private func iPadViewport(layout: String) throws -> CGSize? {
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let bounds = scene.screen.bounds
        let size: CGSize? = switch layout {
        case "narrow": CGSize(width: 320, height: 600)
        case "medium": CGSize(width: 640, height: 600)
        case "landscape": CGSize(width: max(bounds.width, bounds.height), height: min(bounds.width, bounds.height))
        default: CGSize(width: min(bounds.width, bounds.height), height: max(bounds.width, bounds.height))
        }
        return size
    }

    private func iPadLauncherInventory(label: String, size: CGSize?, dark: Bool,
                                       textSize: DynamicTypeSize) async throws {
        for count in [0, 1, 12] {
            let model = iPadLibrary(count: count)
            model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
            if let pc = model.savedPCs.first {
                model.select(pc)
                await model.waitUntilOperationFinishes()
            }
            try await record(LauncherView(model: model), name: "\(label)-launcher-\(count)",
                             size: size, dark: dark, textSize: textSize)
            if count == 12 {
                try await record(LauncherView(model: model, style: .covers), name: "\(label)-covers",
                                 size: size, dark: dark, textSize: textSize)
            }
        }
        try await record(PairingView(prompt: .init(name: "Living room gaming PC", pin: "1234"), cancel: {}),
                         name: "\(label)-pairing", size: size, dark: dark, textSize: textSize)
        try await record(AddPCView(connect: { _ in }), name: "\(label)-add-pc", size: size,
                         dark: dark, textSize: textSize)
        let fixture = LauncherFixture()
        fixture.prepareFailure = LauncherServices.Failure.invalidIdentity
        let failed = fixture.model()
        failed.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        failed.select(fixture.saved)
        await failed.waitUntilOperationFinishes()
        try await record(LauncherView(model: failed), name: "\(label)-pairing-failure",
                         size: size, dark: dark, textSize: textSize)
    }

    @Test func iPadNarrowStreamInventory() async throws {
        let id = UUID()
        let model = StreamSessionModel(launch: testLaunch(), makePlayback: { _, _, _ in
            StreamPlayback(id: id, events: AsyncStream { _ in }, start: {}, stop: {}, screenChanged: {},
                           format: StreamFormat(width: 1920, height: 1080, fps: 60))
        })
        let controller = StreamViewController(model: model, close: {})
        try await recordController(controller, name: "ipad-native-narrow-stream", size: CGSize(width: 320, height: 600),
                                   dark: true, prepare: {
            Attachment.record(Array("phase: \(model.phase)".utf8), named: "ipad-native-narrow-stream-phase.txt")
        })
        #expect(controller.view.bounds.size == CGSize(width: 320, height: 600))
        model.stop()
        await model.waitUntilStopped()
    }

    private func iPadLibrary(count: Int) -> LauncherModel {
        let launch = testLaunch()
        let pcs = (0..<count).map { index in
            var server = ServerInfo(address: "pc.invalid", uniqueId: "ipad-\(index)",
                                    serverName: "Living room gaming PC \(index + 1)")
            server.pairStatus = .paired
            return SavedPC(server: server)
        }
        let titles = ["Desktop", "Steam Big Picture", "A game with a long title that needs room to wrap", "Racing"]
        let apps = (0..<count).map { index in
            HostApp(id: index, name: titles[index % titles.count], hdrCapable: false, hidden: false)
        }
        let calls = LauncherModel.Calls(savedPCs: { pcs },
            prepare: { server, _ in PreparedPC(network: launch.network, server: server) },
            pair: { pc, _ in pc }, apps: { _ in apps }, remember: { _ in pcs }, protectedDataChanged: { _ in },
            artwork: { _, _ in Data() })
        return LauncherModel(calls: calls, discoveryEnabled: false)
    }

    private func iPadStreamInventory(label: String, size: CGSize?,
                                     textSize: DynamicTypeSize) async throws {
        for state in ["connecting", "controls", "playing", "waiting", "reconnecting", "disconnected"] {
            let id = UUID()
            let model = StreamSessionModel(launch: testLaunch(), makePlayback: { _, _, _ in
                StreamPlayback(id: id, events: AsyncStream { _ in }, start: {}, stop: {}, screenChanged: {},
                               format: StreamFormat(width: 1920, height: 1080, fps: 60))
            })
            model.start(surface: StreamSurface())
            if ["controls", "playing", "waiting"].contains(state) {
                model.receive(.init(sessionID: id, attemptID: UUID(), event: .firstFrame))
                if state == "controls" { model.showControls() } else { model.resumeInput() }
            }
            if state == "waiting" {
                model.receive(.init(sessionID: id, attemptID: UUID(), event: .waitingForVideo(true)))
            }
            if state == "reconnecting" {
                model.receive(.init(sessionID: id, attemptID: UUID(), event: .reconnecting))
            }
            if state == "disconnected" { model.stop(); await model.waitUntilStopped() }
            try await record(ZStack { Color.black.ignoresSafeArea(); StreamControls(model: model, close: {}) },
                             name: "\(label)-stream-\(state)", size: size, dark: true, textSize: textSize)
            model.stop()
            await model.waitUntilStopped()
        }
    }

    func recordIPadGeometry(_ view: UIView, name: String) {
        let traits = view.traitCollection
        let details = """
        bounds: \(view.bounds)
        safeArea: \(view.safeAreaInsets)
        horizontalSizeClass: \(traits.horizontalSizeClass.rawValue)
        verticalSizeClass: \(traits.verticalSizeClass.rawValue)
        contentSizeCategory: \(traits.preferredContentSizeCategory.rawValue)
        """
        Attachment.record(Array(details.utf8), named: "\(name)-geometry.txt")
    }
}
