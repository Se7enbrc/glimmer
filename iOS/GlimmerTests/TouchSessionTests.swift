// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import GameController
import GlimmerEngine
import Testing
@testable import Glimmer

@MainActor
struct TouchSessionTests {
    @Test func touchNeutralFollowsGlobalFocusAndOldContactsCannotResume() async throws {
        let connection = StreamConnection(video: ConnectionTestVideoSink()) { _, _ in }
        var order: [String] = []
        let touch = TouchGamepadCapture(calls: .init(register: connection.input.registerController,
            unregister: connection.input.unregisterController, submit: { _, _, _ in order.append("sample") }))
        let physical = IOSControllerCapture(calls: .init(register: connection.input.registerController,
            unregister: connection.input.unregisterController, submit: { _, _, _ in },
            focus: { order.append("focus:\($0)") }), center: NotificationCenter(), readControllers: { [] })
        let lifetime = NativeInputLifetime()
        lifetime.start(input: connection.input, controllers: physical, touch: touch)
        lifetime.focus(true)
        #expect(order == ["focus:true", "sample"])
        let old = try #require(touch.begin(.a))
        touch.update(old, value: CGPoint(x: 1, y: 0), at: 1)
        lifetime.focus(false)
        lifetime.focus(true)
        let count = order.count
        touch.update(old, value: CGPoint(x: 1, y: 0), at: 2)
        #expect(order.count == count)
        #expect(order.suffix(2) == ["focus:true", "sample"])
        lifetime.stop()
        await connection.stop()
    }

    @Test func unusableGeometryReleasesInputAndPreservesExplicitMenuIntent() async {
        let id = UUID()
        let model = StreamSessionModel(launch: testLaunch(), makePlayback: { _, _, _ in
            StreamPlayback(id: id, events: AsyncStream { _ in }, start: {}, stop: {}, screenChanged: {})
        })
        model.start(surface: StreamSurface())
        model.receive(.init(sessionID: id, attemptID: UUID(), event: .firstFrame))
        #expect(model.inputFocused)
        model.touchGeometryChanged(usable: false)
        #expect(!model.inputFocused && model.controlsVisible)
        model.resumeInput()
        #expect(!model.inputFocused && model.controlsVisible)
        model.touchGeometryChanged(usable: true)
        #expect(model.inputFocused)
        model.showControls()
        model.touchGeometryChanged(usable: false)
        model.touchGeometryChanged(usable: true)
        #expect(!model.inputFocused && model.controlsVisible)
        model.stop()
        await model.waitUntilStopped()
    }

    @Test func firstFrameWithoutHardwareStartsTouchPlay() async {
        let id = UUID()
        let model = StreamSessionModel(launch: testLaunch(), makePlayback: { _, _, _ in
            StreamPlayback(id: id, events: AsyncStream { _ in }, start: {}, stop: {}, screenChanged: {})
        })
        model.start(surface: StreamSurface())
        model.receive(.init(sessionID: id, attemptID: UUID(), event: .firstFrame))
        #expect(model.inputFocused)
        #expect(model.controlsVisible == false)
        model.showControls()
        model.editingTouchControls = true
        model.stop()
        await model.waitUntilStopped()
        #expect(model.editingTouchControls == false)
    }
}
