// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AppKit
import GlimmerEngine
import Testing
@testable import Glimmer

@MainActor
@Suite(.serialized)
struct ControllerLayoutOwnershipTests {
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

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }
}
