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

    @Test func hotplugCountsOnlyPhysicalRegistrationsAndOverrideKeepsSeparateSlots() async throws {
        let connection = StreamConnection(video: ConnectionTestVideoSink()) { _, _ in }
        let lifetime = NativeInputLifetime()
        let touch = TouchGamepadCapture(input: connection.input)
        let center = NotificationCenter()
        // Snapshot controllers stand in for hardware only at the injected discovery boundary.
        let first = GCController.withExtendedGamepad()
        let second = GCController.withExtendedGamepad()
        var discovered: [GCController] = []
        var registrations: [ControllerRegistration] = []
        let physical = IOSControllerCapture(calls: .init(register: { descriptor in
            let result = connection.input.registerController(descriptor)
            if let result { registrations.append(result) }
            return result
        }, unregister: connection.input.unregisterController, submit: { _, _, _ in },
            focus: { connection.input.setFocused($0) }), center: center, readControllers: { discovered })
        lifetime.start(input: connection.input, controllers: physical, touch: touch)
        var presence: [Bool] = []
        lifetime.observeControllers { presence.append($0) }
        lifetime.focus(true)
        #expect(touch.enabled && presence == [false])
        let original = try #require(touch.registration)
        let old = try #require(touch.begin(.a))
        touch.update(old, value: CGPoint(x: 1, y: 0), at: 1)
        discovered = [first]
        center.post(name: .GCControllerDidConnect, object: first)
        #expect(touch.registration == nil && !touch.enabled && presence == [false, true])
        #expect(registrations.first?.slot == original.slot)
        discovered = [first, second]
        center.post(name: .GCControllerDidConnect, object: second)
        #expect(presence == [false, true] && registrations.count == 2)
        discovered = [second]
        center.post(name: .GCControllerDidDisconnect, object: first)
        #expect(touch.registration == nil && presence == [false, true])
        lifetime.showTouchControls(true)
        let overlay = try #require(touch.registration)
        #expect(touch.enabled && overlay.slot != registrations.last?.slot)
        physical.refresh()
        #expect(presence == [false, true] && registrations.count == 2)
        lifetime.showTouchControls(false)
        #expect(touch.registration == nil && presence == [false, true])
        discovered = []
        center.post(name: .GCControllerDidDisconnect, object: second)
        #expect(touch.enabled && presence == [false, true, false])
        touch.update(old, value: CGPoint(x: 1, y: 0), at: 2)
        #expect(touch.begin(.a) != nil)
        lifetime.showTouchControls(true)
        discovered = [first, second]
        physical.refresh()
        #expect(touch.enabled && presence == [false, true, false, true])
        #expect(registrations.suffix(2).allSatisfy { $0.slot != touch.registration?.slot })
        lifetime.stop()
        #expect(touch.registration == nil && presence.last == false)
        let next = IOSControllerCapture(calls: .init(register: connection.input.registerController,
            unregister: connection.input.unregisterController, submit: { _, _, _ in }, focus: { _ in }),
            center: NotificationCenter(), readControllers: { [first] })
        lifetime.start(input: connection.input, controllers: next, touch: touch)
        lifetime.focus(true)
        #expect(touch.registration == nil)
        lifetime.stop()
        await connection.stop()
    }

    @Test(arguments: [false, true])
    func overrideIsSessionOnlyAndEngineActivityIsNotPhysicalPresence(remoteEnd: Bool) async {
        let id = UUID()
        var presence: ((Bool) -> Void)?
        var requests: [Bool] = []
        let model = StreamSessionModel(launch: testLaunch(), makePlayback: { _, _, _ in
            StreamPlayback(id: id, events: AsyncStream { _ in }, start: {}, stop: {}, screenChanged: {},
                           observeControllers: { presence = $0; $0(false) },
                           showTouchControls: { requests.append($0) })
        })
        model.start(surface: StreamSurface())
        await model.waitUntilStartFinishes()
        model.receive(.init(sessionID: id, attemptID: UUID(), event: .firstFrame))
        model.receive(.init(sessionID: id, attemptID: UUID(), event: .input(.controllersActive(true))))
        #expect(!model.controllerConnected && model.touchControlsVisible)
        model.toggleTouchControls()
        #expect(!model.touchControlsRequested && requests.isEmpty)
        presence?(true)
        #expect(model.inputFocused && !model.touchControlsVisible)
        model.receive(.init(sessionID: id, attemptID: UUID(), event: .input(.controllersActive(false))))
        #expect(model.controllerConnected && !model.touchControlsVisible)
        model.showControls()
        model.toggleTouchControls()
        #expect(model.touchControlsRequested && !model.touchControlsVisible && requests == [true])
        model.resumeInput()
        #expect(model.touchControlsVisible)
        model.toggleTouchControls()
        #expect(!model.touchControlsVisible && requests == [true, false])
        model.toggleTouchControls()
        presence?(false)
        #expect(model.touchControlsVisible && !model.controllerConnected)
        model.toggleTouchControls()
        #expect(requests == [true, false, true])
        presence?(true)
        #expect(model.touchControlsVisible && model.touchControlsRequested)
        model.receive(.init(sessionID: id, attemptID: UUID(), event: .reconnecting))
        #expect(!model.touchControlsVisible && model.touchControlsRequested)
        model.receive(.init(sessionID: id, attemptID: UUID(), event: .reconnected))
        #expect(model.touchControlsVisible)
        if remoteEnd {
            model.receive(.init(sessionID: id, attemptID: UUID(), event: .stopped))
        } else {
            model.stop()
            await model.waitUntilStopped()
        }
        #expect(!model.touchControlsRequested && !model.touchControlsVisible)
        #expect(requests.last == false)
        presence?(true)
        model.toggleTouchControls()
        #expect(!model.controllerConnected && !model.touchControlsRequested)
    }
}
