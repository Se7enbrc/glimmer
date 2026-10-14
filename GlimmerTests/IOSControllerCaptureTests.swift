// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GameController
import GlimmerEngine
import Testing
@testable import Glimmer

@MainActor
struct IOSControllerCaptureTests {
    @Test func capturePreservesNormalizedAxesAndActualButtons() throws {
        let controller = GCController.withExtendedGamepad()
        let pad = try #require(controller.extendedGamepad)
        pad.leftTrigger.setValue(0.25)
        pad.rightThumbstick.xAxis.setValue(-0.5)
        pad.buttonA.setValue(1)
        let sample = IOSControllerCapture.sample(pad)
        #expect(sample.leftTrigger == 0.25)
        #expect(sample.rightStickX == -0.5)
        #expect(sample.buttons.contains(.a))
        #expect(!sample.buttons.contains(.b))
        let descriptor = IOSControllerCapture.descriptor(controller, pad: pad)
        #expect(descriptor.supportedButtons.contains(.menu))
        #expect(descriptor.capabilities == [.analogTriggers])
        #expect(sample.touchpad == nil)
    }

    @Test func resumeSamplesBeforeOpeningFocusAndRestoresNativeOwnership() async throws {
        let fixture = ControllerCaptureFixture()
        let pad = try #require(fixture.controller.extendedGamepad)
        let priorQueue = DispatchQueue(label: "io.ugfugl.Glimmer.test-controller")
        fixture.controller.handlerQueue = priorQueue
        let priorGesture = pad.buttonMenu.preferredSystemGestureState
        let capture = fixture.make()
        capture.start()
        capture.start()
        #expect(fixture.registrations.count == 1)
        pad.buttonA.setValue(1)
        capture.setFocused(true)
        #expect(fixture.events == ["sample", "focus:true"])
        #expect(fixture.samples.last?.buttons.contains(.a) == true)
        #expect(fixture.controller.handlerQueue === DispatchQueue.main)
        capture.setFocused(false)
        #expect(fixture.events.last == "focus:false")
        #expect(fixture.controller.handlerQueue === priorQueue)
        #expect(pad.buttonMenu.preferredSystemGestureState == priorGesture)
        #expect(pad.valueChangedHandler == nil)
        capture.stop()
        #expect(fixture.events.suffix(2) == ["focus:false", "remove"])
        await fixture.connection.stop()
    }

    @Test func focusedHotplugSamplesHeldControlsWithoutWaitingForNativeChange() async throws {
        let fixture = ControllerCaptureFixture()
        fixture.visible = false
        let pad = try #require(fixture.controller.extendedGamepad)
        pad.buttonA.setValue(1)
        pad.leftThumbstick.xAxis.setValue(0.5)
        let capture = fixture.make()
        capture.start()
        capture.setFocused(true)
        #expect(fixture.samples.isEmpty)
        fixture.now = 200
        fixture.visible = true
        fixture.center.post(name: .GCControllerDidConnect, object: fixture.controller)
        #expect(fixture.registrations.count == 1)
        #expect(fixture.samples.count == 1)
        #expect(fixture.samples.first?.buttons.contains(.a) == true)
        #expect(fixture.samples.first?.leftStickX == 0.5)
        #expect(fixture.timestamps == [200])
        #expect(fixture.events == ["focus:true", "sample"])
        #expect(pad.valueChangedHandler != nil)
        capture.refresh()
        #expect(fixture.samples.count == 1)
        capture.stop()
        await fixture.connection.stop()
    }

    @Test func detachedRegistrationRejectsAlreadyQueuedCallbackOnSameController() async throws {
        let fixture = ControllerCaptureFixture()
        let pad = try #require(fixture.controller.extendedGamepad)
        let capture = fixture.make()
        capture.start()
        capture.setFocused(true)
        let obsolete = try #require(pad.valueChangedHandler)
        let first = try #require(fixture.registrations.first)
        fixture.visible = false
        capture.refresh()
        fixture.visible = true
        capture.refresh()
        let second = try #require(fixture.registrations.last)
        #expect(first != second)
        #expect(first.slot == second.slot)
        let before = fixture.samples.count
        obsolete(pad, pad.buttonA)
        #expect(fixture.samples.count == before)
        let current = try #require(pad.valueChangedHandler)
        current(pad, pad.buttonA)
        #expect(fixture.samples.count == before + 1)
        #expect(fixture.timestamps.last == pad.lastEventTimestamp)
        capture.stop()
        current(pad, pad.buttonA)
        #expect(fixture.samples.count == before + 1)
        fixture.center.post(name: .GCControllerDidConnect, object: nil)
        #expect(fixture.registrations.count == 2)
        await fixture.connection.stop()
    }
}

@MainActor
private final class ControllerCaptureFixture {
    let controller = GCController.withExtendedGamepad()
    let center = NotificationCenter()
    let connection = StreamConnection(video: ConnectionTestVideoSink()) { _, _ in }
    var visible = true
    var now: TimeInterval = 100
    var registrations: [ControllerRegistration] = []
    var samples: [ControllerInputSample] = []
    var timestamps: [TimeInterval] = []
    var events: [String] = []

    func make() -> IOSControllerCapture {
        IOSControllerCapture(calls: .init(register: { [self] descriptor in
            guard let registration = connection.input.registerController(descriptor) else { return nil }
            registrations.append(registration)
            return registration
        }, unregister: { [self] registration in
            events.append("remove")
            connection.input.unregisterController(registration)
        }, submit: { [self] _, sample, timestamp in
            samples.append(sample)
            timestamps.append(timestamp)
            events.append("sample")
        }, focus: { [self] focus in events.append("focus:\(focus)") }), center: center,
           readControllers: { [self] in visible ? [controller] : [] }, clock: { [self] in now })
    }
}
