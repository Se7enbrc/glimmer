// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

@testable import GlimmerEngine
import Foundation
import os
import Testing

@MainActor
struct StreamInputMouseModeTests {
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var descriptor: ControllerDescriptor {
        ControllerDescriptor(kind: .unknown, supportedButtons: [.a, .b, .menu, .leftShoulder, .rightShoulder],
                             capabilities: [.analogTriggers, .touchpad])
    }

    private struct Rig {
        let input: StreamInput
        let backend: InputRecordingBackend
        let events: OSAllocatedUnfairLock<[StreamInput.Event]>
    }

    private func rig(ready: Bool = true) -> Rig {
        let backend = InputRecordingBackend()
        let events = OSAllocatedUnfairLock(initialState: [StreamInput.Event]())
        let input = StreamInput(backend: backend, emit: { event in events.withLock { $0.append(event) } })
        if ready { input.activate(true); input.setFocused(true) }
        return Rig(input: input, backend: backend, events: events)
    }

    // Tests drive the existing poll directly; no wall-clock timer is needed to prove mapping or stale epochs.
    private func submit(_ input: StreamInput, _ registration: ControllerRegistration, _ sample: ControllerInputSample,
                        capturedAt: TimeInterval? = nil) {
        input.core.withLock {
            input.submitController(registration, sample: sample, capturedAt: capturedAt ?? now)
            input.core.controllerMouseTimer?.cancel()
            input.core.controllerMouseTimer = nil
        }
    }

    private func toggle(_ input: StreamInput, _ registration: ControllerRegistration) {
        let start = now
        submit(input, registration, .init(buttons: .menu), capturedAt: start)
        submit(input, registration, .init(), capturedAt: start + 0.751)
    }

    @Test func gamepadModeNeverEvaluatesMouseMotion() {
        var calls = 0
        func motion() -> (pointer: SIMD2<Int16>, scroll: SIMD2<Int16>) {
            calls += 1
            return ControllerMousePlan().sticks(.init(leftTrigger: 0, rightTrigger: 0,
                leftStickX: 32767, leftStickY: 32767, rightStickX: 32767, rightStickY: 32767))
        }
        let gamepad = ControllerMouseState()
        for _ in 0..<1024 {
            let moving = gamepad.isMoving(motion())
            #expect(!moving)
        }
        #expect(calls == 0)
        let mouse = ControllerMouseState(isMouse: true)
        let moving = mouse.isMoving(motion())
        #expect(moving)
        #expect(calls == 1)
        #expect(!mouse.isMoving((.zero, .zero)))
    }

    @Test func nativeMenuHoldKeepsMouseModeAndExplicitSwitchRejectsStaleControllers() throws {
        let rig = rig()
        defer { rig.input.stop() }
        rig.input.setControllerMenuOpensControls(true)
        let controller = try #require(rig.input.registerController(descriptor))
        toggle(rig.input, controller)
        #expect(rig.events.withLock { $0.contains(.controlsRequested(controller)) })
        #expect(rig.input.core.withLock { rig.input.core.controllerMouseStates[controller.slot]?.isMouse } == false)
        rig.input.setControllerMouseMode(true, for: controller)
        #expect(rig.events.withLock { $0.last } == .mouseMode(controller, enabled: true))
        toggle(rig.input, controller)
        #expect(rig.events.withLock { $0.last } == .controlsRequested(controller))
        #expect(rig.input.core.withLock { rig.input.core.controllerMouseStates[controller.slot]?.isMouse } == true)
        rig.input.setControllerMouseMode(false, for: controller)
        #expect(rig.events.withLock { $0.last } == .mouseMode(controller, enabled: false))
        rig.input.unregisterController(controller)
        let replacement = try #require(rig.input.registerController(descriptor))
        rig.input.setControllerMouseMode(true, for: controller)
        #expect(rig.input.core.withLock { rig.input.core.controllerMouseStates[replacement.slot]?.isMouse } != true)
    }

    @Test(arguments: [ControllerMouseMapping.leftStick, .rightStick])
    func selectedHandMovesPointerAndOppositeHandScrolls(mapping: ControllerMouseMapping) throws {
        let rig = rig()
        defer { rig.input.stop() }
        rig.input.setControllerMouseMapping(mapping)
        let registration = try #require(rig.input.registerController(descriptor))
        toggle(rig.input, registration)
        submit(rig.input, registration, .init(leftStickX: 1, rightStickY: 1))
        rig.input.core.pollControllerMouse()
        if mapping == .rightStick {
            #expect(rig.backend.mouseMoves == [.init(dx: 0, dy: -10)])
            #expect(rig.backend.pointer == [.hScroll(10)])
        } else {
            #expect(rig.backend.mouseMoves == [.init(dx: 10, dy: 0)])
            #expect(rig.backend.pointer == [.scroll(10)])
        }
    }

    @Test(arguments: [ControllerMouseMapping.leftStick, .rightStick])
    func triggerUsesSharedPressThresholdAndSameHandShoulderClicksSecondary(mapping: ControllerMouseMapping) throws {
        let rig = rig()
        defer { rig.input.stop() }
        rig.input.setControllerMouseMapping(mapping)
        let registration = try #require(rig.input.registerController(descriptor))
        toggle(rig.input, registration)
        func sample(_ trigger: Float, shoulder: Bool = false) -> ControllerInputSample {
            if mapping == .rightStick {
                return .init(buttons: shoulder ? .rightShoulder : [], rightTrigger: trigger)
            }
            return .init(buttons: shoulder ? .leftShoulder : [], leftTrigger: trigger)
        }
        submit(rig.input, registration, sample(127 / 255))
        #expect(rig.backend.pointer.isEmpty)
        submit(rig.input, registration, sample(128 / 255))
        submit(rig.input, registration, sample(1))
        #expect(rig.backend.pointer == [.button(action: 7, button: 1)])
        submit(rig.input, registration, sample(127 / 255, shoulder: true))
        #expect(rig.backend.pointer == [.button(action: 7, button: 1), .button(action: 8, button: 1),
                                        .button(action: 7, button: 3)])
        submit(rig.input, registration, .init(buttons: [.a, .b]))
        #expect(rig.backend.pointer.last == .button(action: 8, button: 3))
        #expect(rig.backend.pointer.count == 4)
    }

    @Test func liveMappingChangeReleasesAndIndependentlyRearmsHeldControls() throws {
        let rig = rig()
        defer { rig.input.stop() }
        rig.input.setControllerMouseMapping(.rightStick)
        let registration = try #require(rig.input.registerController(descriptor))
        toggle(rig.input, registration)
        let held = ControllerInputSample(buttons: [.leftShoulder, .rightShoulder], leftTrigger: 1,
                                         rightTrigger: 1, leftStickX: 1, rightStickX: 1)
        submit(rig.input, registration, held)
        #expect(rig.backend.pointer == [1, 3, 4, 5].map { .button(action: 7, button: $0) })
        rig.input.setControllerMouseMapping(.leftStick)
        #expect(rig.backend.pointer.suffix(4) == [1, 3, 4, 5].map { .button(action: 8, button: $0) })
        submit(rig.input, registration, held)
        rig.input.core.pollControllerMouse()
        #expect(rig.backend.pointer.count == 8 && rig.backend.mouseMoves.isEmpty)
        submit(rig.input, registration, .init(rightTrigger: 1, rightStickX: 1))
        submit(rig.input, registration, held)
        #expect(rig.backend.pointer.suffix(3) == [1, 3, 5].map { .button(action: 7, button: $0) })
        #expect(rig.input.core.withLock { rig.input.core.controllerMouseStates[registration.slot]?.analog.rightStickX } == 0)
    }

    @Test func mappingChangePreservesFailedClickReleaseAndRejectsQueuedCaptureAndPoll() throws {
        let rig = rig()
        defer { rig.input.stop() }
        rig.input.setControllerMouseMapping(.rightStick)
        let registration = try #require(rig.input.registerController(descriptor))
        toggle(rig.input, registration)
        submit(rig.input, registration, .init(rightTrigger: 1, rightStickX: 1))
        let generation = rig.input.core.withLock { rig.input.core.mousePollingGeneration }
        let capturedBeforeChange = now
        rig.backend.inputResult = -2
        rig.input.setControllerMouseMapping(.leftStick)
        #expect(rig.input.core.withLock { rig.input.core.releases.pending.contains(.mouse(1)) })
        submit(rig.input, registration, .init(leftTrigger: 1, leftStickX: 1), capturedAt: capturedBeforeChange)
        rig.input.core.pollControllerMouse(generation: generation)
        #expect(rig.backend.mouseMoves.isEmpty)
        #expect(rig.backend.pointer == [.button(action: 7, button: 1)])
        rig.backend.inputResult = 0
        rig.input.reconcile()
        #expect(rig.backend.pointer == [.button(action: 7, button: 1), .button(action: 8, button: 1)])
        submit(rig.input, registration, .init(leftTrigger: 1, leftStickX: 1))
        rig.input.core.pollControllerMouse()
        #expect(rig.backend.pointer.last == .button(action: 7, button: 1))
        #expect(rig.backend.mouseMoves == [.init(dx: 10, dy: 0)])
    }

    @Test func mappingBeforeActivationSendsNothingAndUnregisterClearsOnlyTheRetiredMode() throws {
        let rig = rig(ready: false)
        defer { rig.input.stop() }
        let old = try #require(rig.input.registerController(descriptor))
        rig.input.setControllerMouseMapping(.rightStick)
        #expect(rig.backend.controllerEvents.isEmpty && rig.backend.pointer.isEmpty && rig.backend.mouseMoves.isEmpty)
        rig.input.activate(true)
        rig.input.setFocused(true)
        toggle(rig.input, old)
        rig.input.unregisterController(old)
        let replacement = try #require(rig.input.registerController(descriptor))
        #expect(replacement.slot == old.slot && replacement != old)
        #expect(rig.input.core.withLock { rig.input.core.controllerMouseStates[replacement.slot] == nil })
        #expect(rig.events.withLock { $0.suffix(2) }
            == [.mouseMode(old, enabled: true), .mouseMode(old, enabled: false)])
        submit(rig.input, old, .init(rightTrigger: 1))
        #expect(rig.backend.pointer.isEmpty)
        toggle(rig.input, replacement)
        submit(rig.input, replacement, .init(rightTrigger: 1))
        #expect(rig.backend.pointer == [.button(action: 7, button: 1)])
        rig.input.stop()
        rig.input.setControllerMouseMapping(.leftStick)
        #expect(rig.input.core.withLock { rig.input.core.controllerMouseMapping } == .rightStick)
    }

    @Test func focusAndRecoveryPreserveModeWhileReleasingAndRearmingClicks() throws {
        let rig = rig()
        defer { rig.input.stop() }
        rig.input.setControllerMouseMapping(.rightStick)
        let registration = try #require(rig.input.registerController(descriptor))
        toggle(rig.input, registration)
        submit(rig.input, registration, .init(rightTrigger: 1))
        rig.input.setFocused(false)
        #expect(rig.backend.pointer.last == .button(action: 8, button: 1))
        rig.input.setFocused(true)
        submit(rig.input, registration, .init(rightTrigger: 1))
        #expect(rig.backend.pointer.count == 2)
        let replacement = InputRecordingBackend()
        let attempt = UUID()
        rig.input.prepareForReplacement(attempt: rig.input.initialAttempt)
        #expect(rig.input.rebind(to: replacement, attempt: attempt))
        rig.input.activate(true, attempt: attempt)
        #expect(rig.input.core.withLock { rig.input.core.controllerMouseStates[registration.slot]?.isMouse } == true)
        submit(rig.input, registration, .init(rightTrigger: 1))
        #expect(replacement.pointer == [.button(action: 8, button: 1)])
        submit(rig.input, registration, .init())
        submit(rig.input, registration, .init(rightTrigger: 1))
        #expect(replacement.pointer == [.button(action: 8, button: 1), .button(action: 7, button: 1)])
    }

    @Test func rejectedTouchDownRetriesBeforeMoveOrRelease() throws {
        let rig = rig()
        defer { rig.input.stop() }
        let registration = try #require(rig.input.registerController(descriptor))
        let contact = ControllerInputSample(touchpad: .init(
            primaryX: 0.4, primaryY: 0.4, secondaryX: 0, secondaryY: 0, clicked: false))
        rig.backend.touchResult = -1
        submit(rig.input, registration, contact)
        #expect(rig.backend.touches.isEmpty)
        #expect(rig.input.core.withLock { rig.input.core.touchpadStates[registration.slot]?.primary.active } == false)

        rig.backend.touchResult = 0
        submit(rig.input, registration, contact)
        submit(rig.input, registration, .init(touchpad: .init(
            primaryX: 0, primaryY: 0, secondaryX: 0, secondaryY: 0, clicked: false)))
        #expect(rig.backend.touches.map(\.eventType) == [UInt8(StreamProtocol.LI_TOUCH_EVENT_DOWN),
                                                       UInt8(StreamProtocol.LI_TOUCH_EVENT_UP)])
        #expect(rig.backend.touches.first?.pointerId == rig.backend.touches.last?.pointerId)
    }

    @Test func rejectedTouchMoveRetriesUnchangedCoordinatesAndPreservesReleaseBarrier() throws {
        let rig = rig()
        defer { rig.input.stop() }
        let registration = try #require(rig.input.registerController(descriptor))
        submit(rig.input, registration, .init(touchpad: .init(
            primaryX: 0.2, primaryY: 0.2, secondaryX: 0, secondaryY: 0, clicked: false)))
        let moved = ControllerInputSample(touchpad: .init(
            primaryX: 0.6, primaryY: 0.6, secondaryX: 0, secondaryY: 0, clicked: false))
        rig.backend.touchResult = -1
        submit(rig.input, registration, moved)
        #expect(rig.backend.touches.count == 1)
        rig.backend.touchResult = 0
        submit(rig.input, registration, moved)
        #expect(rig.backend.touches.last?.eventType == UInt8(StreamProtocol.LI_TOUCH_EVENT_MOVE))
        #expect(rig.backend.touches.last?.x == 0.8)
        rig.backend.touchUpResult = -1
        submit(rig.input, registration, .init(touchpad: .init(
            primaryX: 0, primaryY: 0, secondaryX: 0, secondaryY: 0, clicked: false)))
        #expect(rig.input.core.withLock { rig.input.core.pendingTouchReleases.count } == 1)
        rig.backend.touchUpResult = 0
        rig.input.reconcile()
        #expect(rig.backend.touches.last?.eventType == UInt8(StreamProtocol.LI_TOUCH_EVENT_UP))
        #expect(rig.backend.touches.last?.x == 0.8)
    }

    @Test func menuToggleKeepsFailedTouchReleaseAheadOfNewMouseClicks() throws {
        let rig = rig()
        defer { rig.input.stop() }
        rig.input.setControllerMouseMapping(.rightStick)
        let registration = try #require(rig.input.registerController(descriptor))
        submit(rig.input, registration, .init(touchpad: .init(
            primaryX: 0.4, primaryY: 0.4, secondaryX: 0, secondaryY: 0, clicked: false)))
        #expect(rig.backend.touches.count == 1)
        rig.backend.touchUpResult = -2
        toggle(rig.input, registration)
        submit(rig.input, registration, .init(rightTrigger: 1))
        #expect(rig.backend.pointer.isEmpty)
        #expect(rig.input.core.withLock { rig.input.core.pendingTouchReleases.count } == 1)
        rig.backend.touchUpResult = 0
        rig.input.reconcile()
        #expect(rig.backend.touches.last?.eventType == UInt8(StreamProtocol.LI_TOUCH_EVENT_UP))
        submit(rig.input, registration, .init())
        submit(rig.input, registration, .init(rightTrigger: 1))
        #expect(rig.backend.pointer == [.button(action: 7, button: 1)])
    }

    @Test func changingOneRegistrationDoesNotReleaseAnotherControllersSharedClick() throws {
        let rig = rig()
        defer { rig.input.stop() }
        rig.input.setControllerMouseMapping(.rightStick)
        let first = try #require(rig.input.registerController(descriptor))
        let second = try #require(rig.input.registerController(descriptor))
        toggle(rig.input, first)
        toggle(rig.input, second)
        submit(rig.input, first, .init(rightTrigger: 1))
        submit(rig.input, second, .init(rightTrigger: 1))
        #expect(rig.backend.pointer == [.button(action: 7, button: 1)])
        toggle(rig.input, first)
        #expect(rig.backend.pointer.count == 1)
        rig.input.unregisterController(second)
        #expect(rig.backend.pointer.last == .button(action: 8, button: 1))
    }

    @Test func physicalMenuHoldKeepsExistingToggleAndUsesSelectedMapping() throws {
        let rig = rig()
        defer { rig.input.stop() }
        rig.input.setControllerMouseMapping(.rightStick)
        let registration = try #require(rig.input.registerController(descriptor))
        let start = now
        submit(rig.input, registration, .init(buttons: .menu), capturedAt: start)
        submit(rig.input, registration, .init(), capturedAt: start + 0.751)
        #expect(rig.events.withLock { $0.last } == .mouseMode(registration, enabled: true))
        submit(rig.input, registration, .init(rightStickX: 1), capturedAt: start + 0.8)
        rig.input.core.pollControllerMouse()
        #expect(rig.backend.mouseMoves == [.init(dx: 10, dy: 0)])
        #expect(rig.backend.pointer.isEmpty)
    }
}
