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
        let device = fixture(.dualSense)
        let controls = device.controls
        let sources = ControllerLayout.standard(buttons: ControllerMappedButton.allCases.filter { button in
            controls.contains { $0.id == .button(button) }
        }, extras: ["back-left", "back-right"])
        var layout = sources
        layout.assign(.button(.a), to: .button(.b))
        layout.assign(.extra("back-left"), to: .button(.a))
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
        let source = ControllerLayoutCaptureSource(controls: controls, extras: ["back-left", "back-right"], read: { .init() },
                                                   acquire: { _ in {} })
        try await record(ControllerLayoutCaptureSheet(model: model, device: device, scope: game.id, layout: layout,
            capture: .init(input: source)), name: "after-capture-\(style)", dark: dark)
        #if os(macOS)
        let settings = IsolatedDefaults()
        let app = AppModel(defaults: settings.defaults)
        try await record(NavigationStack { ShortcutsPane().environment(app) }, name: "after-input-\(style)", dark: dark)
        #else
        let launcher = LauncherFixture().model()
        let after = GlimmerSettings(profile: .constant(.native120), stick: .constant(.right), model: launcher)
        try await record(NavigationStack { after.settingsPage(.input) }, name: "after-input-\(style)", dark: dark)
        #endif
    }

    @Test(arguments: [false, true])
    func controllerFamilyScreens(dark: Bool) async throws {
        let style = dark ? "dark" : "light"
        for family in ControllerDiagramFamily.allCases {
            let device = fixture(family)
            for rear in [false, true] where !rear || family == .xbox || family == .dualSense {
                try await record(NavigationStack {
                    Form {
                        Section { ControllerLayoutDiagram(family: family, controls: device.controls, rear: rear) { _ in } }
                        Section("Glimmer controls") { ControllerLayoutShortcutSummary() }
                    }
                    .formStyle(.grouped)
                    .navigationTitle(device.name)
                    #if os(iOS)
                    .navigationBarTitleDisplayMode(.inline)
                    #endif
                }, name: "family-\(family.rawValue)-\(rear ? "back" : "front")-\(style)", dark: dark)
            }
        }
    }

    private func fixture(_ family: ControllerDiagramFamily) -> ControllerLayoutDevice {
        let names: [ControllerDiagramFamily: String] = [.xbox: "Xbox Elite Wireless Controller",
            .dualSense: "DualSense Edge", .dualShock: "DualShock 4", .backbone: "Backbone One", .generic: "MFi controller"]
        let excluded: Set<ControllerMappedButton> = [.paddle1, .paddle2, .paddle3, .paddle4, .touchpad, .share]
        var buttons = ControllerMappedButton.allCases.filter { !excluded.contains($0) }
        if family == .xbox { buttons += [.paddle1, .paddle2, .paddle3, .paddle4] }
        if family.isPlayStation { buttons.append(.touchpad) }
        if family == .dualSense { buttons.append(.share) }
        if family == .backbone { buttons.append(.share) }
        let layout = ControllerLayout.standard(buttons: buttons)
        var labels: [ControllerMappedButton: (String, String)] = [:]
        if family.isPlayStation {
            labels = [.a: ("Cross", "xmark"), .b: ("Circle", "circle"), .x: ("Square", "square"), .y: ("Triangle", "triangle"),
                .home: ("PS button", "playstation.logo"), .share: ("Mute", "mic.slash"),
                .menu: ("Options", "line.3.horizontal"), .options: ("Create", "line.3.horizontal.decrease")]
        } else if family == .xbox {
            labels = [.home: ("Xbox button", "xbox.logo"),
                .leftShoulder: ("LB", "lb.button.roundedbottom.horizontal"),
                .rightShoulder: ("RB", "rb.button.roundedbottom.horizontal")]
        }
        var controls = layout.bindings.map { binding in
            let face: (String, String)?
            if case .button(let button) = binding.source { face = labels[button] } else { face = nil }
            return ControllerLayoutControl(id: binding.source, name: face?.0 ?? binding.source.layoutName,
                symbol: face?.1 ?? binding.source.layoutSymbol)
        }
        if family == .dualSense {
            controls += [.init(id: .extra("back-left"), name: "Left back button", symbol: "button.horizontal",
                               position: .backLeftPrimary),
                         .init(id: .extra("back-right"), name: "Right back button", symbol: "button.horizontal",
                               position: .backRightPrimary)]
        }
        let identity = ControllerLayoutIdentity(category: family.rawValue, profile: "fixture", controls: [])
        return ControllerLayoutDevice(id: family.rawValue, name: names[family] ?? "Controller", identity: identity,
            owner: .type(identity.type), reader: nil, controller: nil, controls: controls, nintendoLabels: false)
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
