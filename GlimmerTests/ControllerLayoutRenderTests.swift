// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI
import Testing
@testable import Glimmer
#if os(macOS)
import AppKit
#else
import UIKit
#endif

@MainActor
@Suite(.serialized)
struct ControllerLayoutRenderTests {
    @Test(arguments: [false, true])
    func nativeLayoutScreens(dark: Bool) async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ControllerLayoutsModel(url: directory.appendingPathComponent("layouts.json"))
        await model.load()
        let game = ControllerLayoutGame(pcID: "fixture-pc", appID: 42, pcName: "Living room PC", name: "Adventure")
        model.games = [game]
        let sources = ControllerLayout.standard(buttons: ControllerMappedButton.allCases, extras: ["rear"])
        let controls = sources.bindings.map {
            ControllerLayoutControl(id: $0.source, name: $0.source == .extra("rear") ? "Rear button" : $0.source.layoutName,
                                    symbol: $0.source.layoutSymbol)
        }
        let identity = ControllerLayoutIdentity(category: "render-fixture", profile: "physical", controls: [])
        let device = ControllerLayoutDevice(id: "fixture", name: "Game controller", identity: identity,
            owner: .type(identity.type), reader: nil, controller: nil, controls: controls, nintendoLabels: false)
        var layout = sources
        layout.assign(.button(.a), to: .button(.b))
        layout.assign(.extra("rear"), to: .button(.a))
        try await model.save(.init(key: .init(owner: device.owner, scope: game.id), name: device.name, layout: layout))
        let style = dark ? "dark" : "light"
        try await record(NavigationStack {
            ControllerLayoutEditor(model: model, device: device, scope: game.id)
        }, name: "after-game-\(style)", dark: dark)
        try await record(NavigationStack {
            ControllerLayoutEditor(model: model, device: device, scope: .allGames)
        }.dynamicTypeSize(.accessibility3), name: "after-large-text-\(style)", dark: dark)
        let control = try #require(controls.first { $0.id == .button(.a) })
        try await record(ControllerLayoutAssignment(model: model, device: device, scope: game.id,
            control: control, layout: layout), name: "after-assignment-\(style)", dark: dark)
        let source = ControllerLayoutCaptureSource(controls: controls, extras: ["rear"], read: { .init() },
                                                   acquire: { _ in {} })
        try await record(ControllerLayoutCaptureSheet(model: model, device: device, scope: game.id, layout: layout,
            capture: .init(input: source, mode: .control)), name: "after-capture-\(style)", dark: dark)
        #if os(macOS)
        let settings = IsolatedDefaults()
        let app = AppModel(defaults: settings.defaults)
        try await record(ControllerLayoutBeforePane().environment(app), name: "before-input-\(style)", dark: dark)
        try await record(NavigationStack { ShortcutsPane().environment(app) }, name: "after-input-\(style)", dark: dark)
        #else
        let launcher = LauncherFixture().model()
        let before = ControllerLayoutBeforeSettings(profile: .constant(.native120), stick: .constant(.right), model: launcher)
        let after = GlimmerSettings(profile: .constant(.native120), stick: .constant(.right), model: launcher)
        try await record(NavigationStack { before.settingsPage(.input) }, name: "before-input-\(style)", dark: dark)
        try await record(NavigationStack { after.settingsPage(.input) }, name: "after-input-\(style)", dark: dark)
        #endif
    }

    private func record<Content: View>(_ content: Content, name: String, dark: Bool) async throws {
        #if os(macOS)
        let host = NSHostingController(rootView: content.environment(\.colorScheme, dark ? .dark : .light))
        let window = NSWindow(contentViewController: host)
        window.title = "Controller layouts"
        window.styleMask = [.titled, .closable, .resizable]
        window.setContentSize(CGSize(width: 620, height: 760))
        let view = host.view
        window.orderFront(nil)
        defer { window.contentViewController = nil; window.contentView = nil; window.close() }
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        let frame = try #require(view.superview)
        let bitmap = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        let directory = ProcessInfo.processInfo.environment["GLIMMER_LAYOUT_SHOTS"].map {
            URL(fileURLWithPath: $0)
        } ?? URL.temporaryDirectory.appendingPathComponent("controller-layout-shots")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent("mac-\(name).png"))
        #else
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let previous = scene.keyWindow
        let window = UIWindow(windowScene: scene)
        let host = UIHostingController(rootView: content.environment(\.colorScheme, dark ? .dark : .light))
        window.rootViewController = host
        window.makeKeyAndVisible()
        defer { window.isHidden = true; window.rootViewController = nil; previous?.makeKey() }
        host.view.layoutIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        host.view.layoutIfNeeded()
        var drawn = false
        let image = UIGraphicsImageRenderer(bounds: host.view.bounds).image { _ in
            drawn = host.view.drawHierarchy(in: host.view.bounds, afterScreenUpdates: true)
        }
        #expect(drawn)
        let data = try #require(image.pngData())
        try data.write(to: URL.documentsDirectory.appendingPathComponent("remapping-\(name).png"))
        #endif
        #expect(data.count > 1000)
        Attachment.record(Array(data), named: "\(name).png")
    }
}
