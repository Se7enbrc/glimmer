// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI
import Testing
@testable import Glimmer
#if os(iOS)
import UIKit
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
            Form {
                Section { ControllerMouseDiagram(bindings: model.mouse, device: device) }
                Section {
                    ForEach(ControllerMouseAction.allCases) { action in
                        LabeledContent(action.title, value: ControllerMouseHelp.describe(model.mouse[action], device: device))
                    }
                }
            }.formStyle(.grouped).navigationTitle("Controller mouse")
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

    private func record<Content: View>(_ content: Content, name: String, dark: Bool) async throws {
        #if os(macOS)
        try await ControllerLayoutRenderTests().record(content, name: name, dark: dark)
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
            name: "\(tablet ? "ipad" : "iphone")-\(name)", size: nil, dark: dark, portrait: true, textSize: .large)
        #endif
    }
}
