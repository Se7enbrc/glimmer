// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AppKit
import GlimmerEngine
import SwiftUI
import Testing
@testable import Glimmer

@MainActor
@Suite(.serialized)
struct ControllerLayoutOwnershipTests {
    @Test func savedGlobalQuitPreferencesRemainAvailableToTheLayoutRouter() {
        let settings = IsolatedDefaults()
        settings.defaults.set("none", forKey: "controllerQuitChord")
        let model = ControllerLayoutsModel(defaults: settings.defaults)
        let identity = ControllerLayoutIdentity(category: "Fixture", profile: "system", controls: [])
        #expect(model.shortcuts(for: identity).stop.isEmpty)
        #expect(model.shortcuts(for: identity).stats == ControllerLayoutShortcuts.defaultStats)
        #expect(settings.defaults.string(forKey: "controllerQuitChord") == "none")
    }

    @Test func closingWhileLayoutsLoadDoesNotStartDeviceObservationAfterDismissal() async throws {
        let identity = ControllerLayoutIdentity(category: "fixture", profile: "physical", controls: [])
        let record = ControllerLayoutRecord(key: .init(owner: .type(identity.type), scope: .allGames),
            name: "Saved controller", layout: .init(bindings: [.init(.button(.a), .button(.b))]))
        var pending: CheckedContinuation<Void, Never>?
        let model = ControllerLayoutsModel(read: {
            await withCheckedContinuation { pending = $0 }
            return .init(records: [record])
        })
        let window = NSWindow(contentViewController: NSHostingController(rootView: NavigationStack {
            ControllerLayoutsView(model: model)
        }))
        window.setContentSize(CGSize(width: 620, height: 500))
        window.makeKeyAndOrderFront(nil)
        try await waitUntil { pending != nil }
        window.contentViewController = nil
        window.close()
        pending?.resume()
        pending = nil
        await model.load()
        await DispatchQueue.main.drainForTest()
        #expect(model.loaded)
        #expect(model.devices.isEmpty)
        #expect(!ControllerLayoutEditing.active)
    }

    @Test func closingTheEditorReturnsMiniPlayerOwnershipAndReleasesTheEditor() async throws {
        let streamWindow = PointerFocusTestWindow(contentRect: .zero, styleMask: .borderless,
                                                   backing: .buffered, defer: true)
        streamWindow.focused = true
        let forwarder = InputForwarder()
        forwarder.window = streamWindow
        forwarder.isMiniPlayer = true
        forwarder.isReady = true
        let layouts = MacControllerLayouts(forwarder: forwarder, scope: .allGames)
        defer { layouts.stop(); forwarder.detach() }
        layouts.showControls()
        try await waitUntil { ControllerLayoutEditing.active }
        #expect(forwarder.controllerOwnershipSuspended)
        #expect(!forwarder.inputCore.snapshot.focused)
        let editor = try #require(NSApplication.shared.windows.first { $0.title == "Controller layouts" })
        editor.close()
        try await waitUntil { !ControllerLayoutEditing.active && !forwarder.controllerOwnershipSuspended }
        #expect(editor.contentViewController == nil)
        #expect(ControllerLayoutEditing.capture == nil)
    }

    @Test(arguments: [0, 3, 25], [false, true])
    func escapeFromTheControllerClosesLayoutsAndReturnsToTheMenu(level: Int, nested: Bool) async throws {
        let forwarder = InputForwarder()
        let menu = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 300),
                            styleMask: .titled, backing: .buffered, defer: false)
        menu.isReleasedWhenClosed = false
        menu.level = NSWindow.Level(rawValue: level)
        let stream = NSWindow(contentRect: menu.frame, styleMask: .titled, backing: .buffered, defer: false)
        stream.isReleasedWhenClosed = false
        stream.level = menu.level
        if nested { stream.addChildWindow(menu, ordered: .above) }
        let layouts = MacControllerLayouts(forwarder: forwarder, scope: .allGames)
        defer { layouts.stop(); forwarder.detach(); stream.removeChildWindow(menu); menu.close(); stream.close() }
        layouts.showControls(returnTo: menu)
        try await waitUntil { ControllerLayoutEditing.active }
        let editor = try #require(NSApplication.shared.windows.first { $0.title == "Controller layouts" })
        #expect(editor.parent === (nested ? stream : menu))
        #expect(editor.level == menu.level)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: editor.windowNumber, context: nil,
            characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53))
        if !editor.performKeyEquivalent(with: event) { editor.firstResponder?.keyDown(with: event) }
        try await waitUntil { !ControllerLayoutEditing.active }
        #expect(editor.contentViewController == nil)
        #expect(editor.parent == nil)
        #expect(menu.isVisible)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }
}
