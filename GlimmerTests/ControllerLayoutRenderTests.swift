// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI
import Testing
@testable import Glimmer
#if os(macOS)
import AppKit
import ApplicationServices
#else
import UIKit
#endif

@MainActor
@Suite(.serialized)
struct ControllerLayoutRenderTests {
    #if os(macOS)
    @Test(arguments: [false, true])
    func statsShortcutScreens(dark: Bool) async throws {
        let settings = IsolatedDefaults()
        let model = AppModel(defaults: settings.defaults)
        let style = dark ? "dark" : "light"
        model.statsHotkey = HotkeyChord(ctrl: true, alt: false, shift: false, cmd: false, keyChar: "i")
        try await record(ShortcutsPane().environment(model), name: "stats-before-\(style)", dark: dark)
        model.statsHotkey = .defaultStats
        try await record(ShortcutsPane().environment(model), name: "stats-after-\(style)", dark: dark)
    }
    #endif

    @Test(arguments: [false, true])
    func nativeLayoutScreens(dark: Bool) async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ControllerLayoutsModel(url: directory.appendingPathComponent("layouts.json"))
        await model.load()
        let game = ControllerLayoutGame(pcID: "fixture-pc", appID: 42, pcName: "Living room PC", name: "Adventure")
        model.games = [game]
        let device = fixture(.dualSenseEdge)
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
            for rear in [false, true] where !rear || family == .xboxElite || family == .dualSenseEdge {
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

    @Test(arguments: [false, true])
    func selectedShoulderOutlinesThePhysicalPart(dark: Bool) async throws {
        let device = fixture(.dualSenseEdge)
        try await record(NavigationStack {
            Form {
                ControllerLayoutDiagram(family: .dualSenseEdge, controls: device.controls,
                                        selectedShoulder: .trigger(.left)) { _ in }
            }
            .formStyle(.grouped)
            .navigationTitle("DualSense Edge")
        }, name: "after-shoulder-selected-\(dark ? "dark" : "light")", dark: dark)
    }

    @Test func everyVisibleDiagramControlHasASpokenName() {
        for family in ControllerDiagramFamily.allCases {
            let controls = fixture(family).controls
            for rear in [false, true] where !rear || family == .dualSenseEdge || family == .xboxElite {
                let names = controls.filter {
                    ControllerDiagramGeometry.visiblePlacement($0, family: family, rear: rear) != nil
                }.map(\.name)
                #expect(!names.isEmpty && names.allSatisfy { !$0.isEmpty }, "\(family) rear: \(rear)")
            }
        }
    }

    #if os(macOS)
    // SwiftUI builds its macOS accessibility tree only for an assistive client, which needs trust.
    @Test(.enabled(if: AXIsProcessTrusted(), "Needs Accessibility trust to read the live tree"))
    func diagramVoiceOverNamesEveryVisibleControl() throws {
        for family in ControllerDiagramFamily.allCases {
            let device = fixture(family)
            for rear in [false, true] where !rear || family == .dualSenseEdge || family == .xboxElite {
                let diagram = ControllerLayoutDiagram(family: family, controls: device.controls, rear: rear) { _ in }
                let host = NSHostingController(rootView: diagram.frame(width: 480, height: 380))
                let window = NSWindow(contentViewController: host)
                defer { window.contentViewController = nil; window.contentView = nil; window.close() }
                window.title = "Controller artwork accessibility test"
                window.orderFront(nil)
                host.view.layoutSubtreeIfNeeded()
                window.displayIfNeeded()
                let app = AXUIElementCreateApplication(getpid())
                let windows = try #require(accessibilityValue(kAXWindowsAttribute, of: app) as? [AXUIElement])
                let accessibleWindow = try #require(windows.first {
                    accessibilityValue(kAXTitleAttribute, of: $0) as? String == window.title
                })
                let labels = accessibilityLabels(accessibleWindow)
                for control in device.controls where ControllerDiagramGeometry.visiblePlacement(
                    control, family: family, rear: rear) != nil {
                    #expect(labels.contains(control.name), "Missing VoiceOver label: \(family) \(control.name)")
                }
                if !rear {
                    for name in ["Left stick", "Right stick", "D-pad"] { #expect(labels.contains(name)) }
                }
            }
        }
    }

    private func accessibilityLabels(_ element: AXUIElement, depth: Int = 0) -> [String] {
        guard depth < 30 else { return [] }
        let label = accessibilityValue(kAXDescriptionAttribute, of: element) as? String
            ?? accessibilityValue(kAXTitleAttribute, of: element) as? String
        let children = accessibilityValue(kAXChildrenAttribute, of: element) as? [AXUIElement] ?? []
        return (label.map { [$0] } ?? []) + children.flatMap { accessibilityLabels($0, depth: depth + 1) }
    }

    private func accessibilityValue(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }
    #endif

    private func fixture(_ family: ControllerDiagramFamily) -> ControllerLayoutDevice {
        let names: [ControllerDiagramFamily: String] = [.xbox: "Xbox Series", .xboxElite: "Xbox Elite Series 2",
            .dualSense: "DualSense", .dualSenseEdge: "DualSense Edge", .dualShock: "DualShock 4",
            .backbone: "Backbone One", .backbonePlayStation: "Backbone One PlayStation Edition", .generic: "MFi controller"]
        let excluded: Set<ControllerMappedButton> = [.paddle1, .paddle2, .paddle3, .paddle4, .touchpad, .share]
        var buttons = ControllerMappedButton.allCases.filter { !excluded.contains($0) }
        if family == .xboxElite { buttons += [.paddle1, .paddle2, .paddle3, .paddle4] }
        if family.isPlayStation { buttons.append(.touchpad) }
        if family.isDualSense || family == .xbox { buttons.append(.share) }
        if family.isBackbone { buttons.append(.share) }
        let layout = ControllerLayout.standard(buttons: buttons)
        var labels: [ControllerMappedButton: (String, String)] = [:]
        if family.isPlayStation || family == .backbonePlayStation {
            labels = [.a: ("Cross", "xmark"), .b: ("Circle", "circle"), .x: ("Square", "square"), .y: ("Triangle", "triangle"),
                .home: ("PS button", "playstation.logo"), .share: ("Mute", "mic.slash"),
                .menu: ("Options", "line.3.horizontal"), .options: ("Create", "line.3.horizontal.decrease")]
            if family.isBackbone {
                labels[.home] = ("Home", "house.circle")
                labels[.share] = ("Capture", "viewfinder")
                labels[.options] = ("Options", "ellipsis")
            }
            if family == .dualShock { labels[.options] = ("Share", "line.3.horizontal.decrease") }
        } else if family.isXbox {
            labels = [.home: ("Xbox button", "xbox.logo"),
                .leftShoulder: ("LB", "lb.button.roundedbottom.horizontal"),
                .rightShoulder: ("RB", "rb.button.roundedbottom.horizontal")]
        }
        var controls = layout.bindings.map { binding in
            let face: (String, String)?
            switch binding.source {
            case .button(let button): face = labels[button]
            case .trigger(let trigger) where family.isXbox:
                face = trigger == .left ? ("LT", "lt.button.roundedtop.horizontal") : ("RT", "rt.button.roundedtop.horizontal")
            default: face = nil
            }
            return ControllerLayoutControl(id: binding.source, name: face?.0 ?? binding.source.layoutName,
                symbol: face?.1 ?? binding.source.layoutSymbol)
        }
        if family == .dualSenseEdge {
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
