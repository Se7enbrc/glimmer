// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GameController
import GlimmerEngine
import Synchronization
import Testing
import UIKit
@testable import Glimmer

@MainActor
struct TouchGamepadTests {
    @Test func nativeActivationAndAccessibilityReleaseTheirContacts() async throws {
        let connection = StreamConnection(video: ConnectionTestVideoSink()) { _, _ in }
        var samples: [ControllerInputSample] = []
        let capture = TouchGamepadCapture(calls: .init(register: connection.input.registerController,
            unregister: connection.input.unregisterController, submit: { _, sample, _ in samples.append(sample) }))
        #expect(capture.attach())
        capture.setEnabled(true)
        samples.removeAll()
        let button = TouchButton(.a)
        button.inputTracking.capture = capture
        button.sendActions(for: .primaryActionTriggered)
        #expect(samples.map(\.buttons) == [.a, []])
        samples.removeAll()
        #expect(button.accessibilityActivate())
        #expect(samples.map(\.buttons) == [.a, []])
        let trigger = TouchTrigger(.leftTrigger)
        trigger.inputTracking.capture = capture
        #expect(trigger.accessibilityActivate())
        #expect(samples.last?.leftTrigger == 1)
        trigger.accessibilityDecrement()
        #expect(samples.last?.leftTrigger == 0.9)
        trigger.accessibilityElementDidLoseFocus()
        #expect(samples.last?.leftTrigger == 0)
        let axis = TouchAxisControl(.leftStick)
        axis.inputTracking.capture = capture
        axis.accessibilityIncrement()
        #expect(samples.last?.leftStickY == 1)
        axis.accessibilityElementDidLoseFocus()
        #expect(samples.last?.leftStickY == 0)
        capture.detach()
        await connection.stop()
    }

    @Test func simultaneousOwnersReleaseIndependentlyAndRejectOldContacts() throws {
        var state = TouchGamepadState()
        let stickValue = state.begin(.leftStick)
        let stick = try #require(stickValue)
        let buttonValue = state.begin(.a)
        let button = try #require(buttonValue)
        let duplicateOwner = state.begin(.a) == nil
        #expect(duplicateOwner)
        let stickChanged = state.update(stick, value: CGPoint(x: 0.5, y: -0.25))
        #expect(stickChanged)
        let buttonPressed = state.update(button, value: CGPoint(x: 1, y: 0))
        #expect(buttonPressed)
        #expect(state.sample.buttons == .a && state.sample.leftStickX == 0.5)
        let heldUnchanged = !state.update(button, value: CGPoint(x: 1, y: 0))
        #expect(heldUnchanged)
        let buttonReleased = state.end(button)
        #expect(buttonReleased)
        #expect(state.sample.buttons.isEmpty && state.sample.leftStickX == 0.5)
        state.reset()
        let replacementValue = state.begin(.a)
        let replacement = try #require(replacementValue)
        let staleUpdateRejected = !state.update(button, value: CGPoint(x: 1, y: 0))
        #expect(staleUpdateRejected)
        let replacementPressed = state.update(replacement, value: CGPoint(x: 1, y: 0))
        #expect(replacementPressed)
        let staleEndRejected = !state.end(button)
        #expect(staleEndRejected)
        #expect(state.sample.buttons == .a)
    }

    @Test func fixedStickDeadZoneAndClampDoNotDependOnPixels() {
        for side in [96.0, 112.0, 144.0] {
            let size = CGSize(width: side, height: side)
            #expect(TouchGamepadState.stick(location: CGPoint(x: side * 0.51, y: side / 2), size: size) == .zero)
            let value = TouchGamepadState.stick(location: CGPoint(x: side * 3, y: -side * 2), size: size)
            #expect(abs(hypot(value.x, value.y) - 1) < 0.00001)
            #expect(value.x > 0 && value.y > 0)
        }
    }

    @Test func dpadSlidesAndTriggerClamps() throws {
        var state = TouchGamepadState()
        let dpadValue = state.begin(.dpad)
        let dpad = try #require(dpadValue)
        let triggerValue = state.begin(.leftTrigger)
        let trigger = try #require(triggerValue)
        let diagonalChanged = state.update(dpad, value: CGPoint(x: -1, y: 1))
        #expect(diagonalChanged)
        #expect(state.sample.buttons == [.dpadLeft, .dpadUp])
        let directionChanged = state.update(dpad, value: CGPoint(x: 1, y: 0))
        #expect(directionChanged)
        #expect(state.sample.buttons == .dpadRight)
        let fullTriggerChanged = state.update(trigger, value: CGPoint(x: 2, y: 0))
        #expect(fullTriggerChanged)
        #expect(state.sample.leftTrigger == 1)
        let releasedTriggerChanged = state.update(trigger, value: CGPoint(x: -1, y: 0))
        #expect(releasedTriggerChanged)
        #expect(state.sample.leftTrigger == 0)
    }

    @Test func adapterPreservesTimestampsAndProducesNoHeldRepeats() async throws {
        let connection = StreamConnection(video: ConnectionTestVideoSink()) { _, _ in }
        var events: [(ControllerInputSample, TimeInterval)] = []
        let capture = TouchGamepadCapture(calls: .init(register: connection.input.registerController,
            unregister: connection.input.unregisterController,
            submit: { _, sample, time in events.append((sample, time)) }))
        #expect(capture.attach())
        capture.setEnabled(true)
        events.removeAll()
        let contact = try #require(capture.begin(.a))
        capture.update(contact, value: CGPoint(x: 1, y: 0), at: 12.5)
        for _ in 0..<1000 { capture.update(contact, value: CGPoint(x: 1, y: 0), at: 12.6) }
        capture.end(contact, at: 12.75)
        #expect(events.map(\.1) == [12.5, 12.75])
        #expect(events.map { $0.0.buttons } == [.a, []])
        capture.setEnabled(false)
        capture.setEnabled(true)
        let count = events.count
        capture.update(contact, value: CGPoint(x: 1, y: 0), at: 13)
        #expect(events.count == count)
        capture.detach()
        await connection.stop()
    }

    @Test func physicalAdmissionRetiresTouchBeforeReusingSlotAndFailureRestoresFallback() async throws {
        let connection = StreamConnection(video: ConnectionTestVideoSink()) { _, _ in }
        let touch = TouchGamepadCapture(input: connection.input)
        #expect(touch.attach())
        let original = try #require(touch.registration)
        touch.setEnabled(true)
        let controller = GCController.withExtendedGamepad()
        var permit = false
        var physicalSlot: UInt8?
        let physical = IOSControllerCapture(calls: .init(register: { descriptor in
            #expect(touch.registration == nil)
            guard permit else { return nil }
            let result = connection.input.registerController(descriptor)
            physicalSlot = result?.slot
            return result
        }, unregister: connection.input.unregisterController, submit: { _, _, _ in }, focus: { _ in }),
            center: NotificationCenter(), readControllers: { [controller] })
        physical.beforeAttach = { touch.detach() }
        physical.refreshed = { connected in if !connected { touch.attach(); touch.setEnabled(true) } }
        physical.start()
        #expect(touch.enabled && touch.registration != nil)
        permit = true
        physical.refresh()
        #expect(touch.registration == nil && !touch.enabled)
        #expect(physicalSlot == original.slot)
        physical.stop()
        await connection.stop()
    }
}
