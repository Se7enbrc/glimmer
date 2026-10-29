// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI
import Testing
@testable import Glimmer
#if os(iOS)
import UIKit
#else
import AppKit
#endif

@MainActor
@Suite(.serialized)
struct ControllerMouseRenderTests {
    @Test(arguments: ControllerMouseMapping.allCases, [false, true])
    func settingsAndDiagram(preset: ControllerMouseMapping, dark: Bool) async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "mouse-render-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let model = ControllerLayoutsModel(url: directory.appendingPathComponent("layouts.json"), defaults: defaults)
        await model.load()
        try model.selectMousePreset(preset)
        let device = ControllerLayoutRenderTests().fixture(.dualSense)
        let name = "mouse-\(preset.rawValue)-\(dark ? "dark" : "light")"
        try await record(NavigationStack {
            ControllerMouseSettingsView(model: model, previewDevice: device)
        }, name: name + "-settings", dark: dark)
        try await record(NavigationStack {
            ControllerMouseSettingsView(model: model, previewDevice: device)
        }, name: name + "-rows", dark: dark, bottom: true)
        try await record(NavigationStack {
            Form {
                Section { ControllerMouseDiagram(bindings: model.mouse, device: device) }
                Section {
                    ForEach(ControllerMouseAction.allCases) { action in
                        LabeledContent(action.title, value: ControllerMouseHelp.describe(model.mouse[action], device: device))
                    }
                }
            }.controllerSettingsForm().navigationTitle("Controller mouse")
        }, name: name + "-diagram", dark: dark)
    }

    @Test(arguments: [false, true])
    func customBindingEditor(dark: Bool) async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "mouse-custom-render-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let model = ControllerLayoutsModel(url: directory.appendingPathComponent("layouts.json"), defaults: defaults)
        await model.load()
        let device = ControllerLayoutRenderTests().fixture(.dualSense)
        try model.saveMouse([.button(.up)], action: .primary, device: device)
        try model.selectMousePreset(.leftStick)
        try await record(NavigationStack {
            ControllerMouseSettingsView(model: model, previewDevice: device)
        }, name: "mouse-custom-\(dark ? "dark" : "light")", dark: dark)
        try await record(ControllerBindingRecorder(model: model, device: device, target: .mouse(.primary)),
            name: "mouse-editor-\(dark ? "dark" : "light")", dark: dark)
    }

    @Test(arguments: [false, true])
    func layoutScreens(dark: Bool) async throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let suite = "layout-parity-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let model = ControllerLayoutsModel(url: directory.appendingPathComponent("layouts.json"), defaults: defaults)
        await model.load()
        let device = ControllerLayoutRenderTests().fixture(.dualSense)
        let style = dark ? "dark" : "light"
        try await model.save(.init(key: .init(owner: device.owner, scope: .allGames), name: device.name,
            layout: model.baseline(device, scope: .allGames), controls: device.controls, category: device.category))
        try await record(NavigationStack { ControllerLayoutsView(model: model) },
                         name: "layout-list-\(style)", dark: dark)
        try await record(NavigationStack {
            ControllerLayoutEditor(model: model, device: device, scope: .allGames)
        }, name: "layout-editor-\(style)", dark: dark)
        try await record(NavigationStack {
            Form { ControllerShortcutSection(model: model, device: device) { _ in } }.controllerSettingsForm()
                .navigationTitle("Glimmer controls")
        }, name: "layout-shortcuts-\(style)", dark: dark)
        try await record(ControllerBindingRecorder(model: model, device: device, target: .shortcut(.stats)),
                         name: "layout-recorder-\(style)", dark: dark)
    }

    private func record<Content: View>(_ content: Content, name: String, dark: Bool, bottom: Bool = false) async throws {
        #if os(macOS)
        try await ControllerLayoutRenderTests().record(content, name: name, dark: dark) { view in
            if bottom, let scroll = Self.scrollViews(view).first, let document = scroll.documentView {
                scroll.contentView.scroll(to: NSPoint(x: 0, y: max(0, document.bounds.height - scroll.contentSize.height)))
                scroll.reflectScrolledClipView(scroll.contentView)
            }
        }
        #else
        let tablet = UIDevice.current.userInterfaceIdiom == .pad
        let renderer = NativeUIRenderTests()
        let scene = try await renderer.activeRenderScene()
        if !tablet, scene.effectiveGeometry.interfaceOrientation != .portrait {
            let presenter = try #require(scene.keyWindow?.rootViewController)
            try await renderer.requestOrientation(scene, .portrait, settling: presenter) {
                scene.effectiveGeometry.interfaceOrientation == .portrait
            }
        }
        let host = UIHostingController(rootView: content)
        try await renderer.recordController(host,
            name: "\(tablet ? "ipad" : "iphone")-\(name)", size: nil, dark: dark, portrait: true,
            prepare: {
                if bottom, let scroll = Self.scrollViews(host.view).first {
                    scroll.setContentOffset(CGPoint(x: 0,
                        y: max(0, scroll.contentSize.height - scroll.bounds.height + scroll.adjustedContentInset.bottom)),
                        animated: false)
                }
            }, textSize: .large)
        #endif
    }
    #if os(macOS)
    private static func scrollViews(_ view: NSView) -> [NSScrollView] {
        (view as? NSScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews($0) }
    }
    #else
    private static func scrollViews(_ view: UIView) -> [UIScrollView] {
        (view as? UIScrollView).map { [$0] } ?? view.subviews.flatMap { scrollViews($0) }
    }
    #endif
}
