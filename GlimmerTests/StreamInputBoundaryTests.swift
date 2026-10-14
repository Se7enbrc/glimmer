// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

@testable import GlimmerEngine
import Foundation
import Testing

struct StreamInputBoundaryTests {
    private var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    private var descriptor: ControllerDescriptor {
        ControllerDescriptor(kind: .unknown, supportedButtons: [.a, .b], capabilities: [.analogTriggers, .touchpad])
    }

    private func rig() -> (StreamInput, InputRecordingBackend) {
        let backend = InputRecordingBackend()
        let input = StreamInput(backend: backend, emit: { _ in })
        input.activate(true)
        return (input, backend)
    }

    @Test func failedArrivalMustSucceedBeforeFirstAcceptedControllerState() throws {
        let (input, backend) = rig()
        defer { input.stop() }
        input.setFocused(true)
        backend.inputResult = -2
        let registration = try #require(input.registerController(descriptor))
        input.submitController(registration, sample: .init(buttons: .a), capturedAt: now)
        #expect(backend.controllerEvents.isEmpty)

        backend.inputResult = 0
        input.submitController(registration, sample: .init(buttons: .a), capturedAt: now)
        #expect(backend.controllerEvents == ["arrival", "state"])
        #expect(backend.calls.last?.buttons == ControllerButtons.a.rawValue)
        input.submitController(registration, sample: .init(buttons: .b), capturedAt: now)
        #expect(backend.controllerEvents == ["arrival", "state", "state"])
    }

    @Test func fractionalPointerMovementAccumulatesAndFocusLossDiscardsTheRemainder() {
        let (input, backend) = rig()
        defer { input.stop() }
        input.setFocused(true)
        for _ in 0..<4 { input.movePointer(dx: 0.25, dy: -0.25, capturedAt: now) }
        #expect(backend.mouseMoves == [MouseMoveSend(dx: 1, dy: -1)])
        input.movePointer(dx: 0.75, dy: -0.75, capturedAt: now)
        #expect(backend.mouseMoves.count == 1)

        input.setFocused(false)
        input.movePointer(dx: 3, dy: -3, capturedAt: now)
        input.setFocused(true)
        input.movePointer(dx: 0.5, dy: -0.5, capturedAt: now)
        #expect(backend.mouseMoves.count == 1)
        input.movePointer(dx: 0.5, dy: -0.5, capturedAt: now)
        #expect(backend.mouseMoves == [MouseMoveSend(dx: 1, dy: -1), MouseMoveSend(dx: 1, dy: -1)])
    }

    @Test func preciseScrollSharesNotchBankAndClearsItOnGestureOrOwnershipEnd() {
        let (input, backend) = rig()
        defer { input.stop() }
        input.setFocused(true)
        input.scroll(x: 6, y: -6, precise: true, capturedAt: now)
        #expect(backend.pointer.isEmpty)
        input.scroll(x: 6, y: -6, precise: true, capturedAt: now)
        #expect(backend.pointer == [.scroll(-120), .hScroll(120)])
        input.endScroll()
        input.scroll(x: 6, y: -6, precise: true, capturedAt: now)
        #expect(backend.pointer.count == 2)
        input.setFocused(false)
        input.setFocused(true)
        input.scroll(x: 6, y: -6, precise: true, capturedAt: now)
        #expect(backend.pointer.count == 2)
        input.scroll(x: 0, y: Double.greatestFiniteMagnitude, precise: false, capturedAt: now)
        #expect(backend.pointer.last == .scroll(Int16.max))
    }

    @Test func resumeSuppressesEachHeldControlWithoutDisablingOtherControls() throws {
        let (input, backend) = rig()
        defer { input.stop() }
        let registration = try #require(input.registerController(descriptor))
        var sample = ControllerInputSample(buttons: .a, leftTrigger: 0.75, rightTrigger: 0.25,
                                            leftStickX: 0.5, rightStickY: -0.5)
        input.submitController(registration, sample: sample, capturedAt: now)
        #expect(backend.calls.isEmpty)
        input.setFocused(true, suppressHeldControls: true)
        sample.buttons.insert(.b)
        sample.leftStickY = 0.25
        input.submitController(registration, sample: sample, capturedAt: now)
        let resumed = try #require(backend.calls.last)
        #expect(resumed.buttons == ControllerButtons.b.rawValue)
        #expect(resumed.analog.leftTrigger == 0 && resumed.analog.rightTrigger == 0)
        #expect(resumed.analog.leftStickX == 0 && resumed.analog.rightStickY == 0)
        #expect(resumed.analog.leftStickY == 8192)

        sample.buttons.remove(.a)
        sample.leftTrigger = 0
        sample.leftStickX = 0
        input.submitController(registration, sample: sample, capturedAt: now)
        sample.buttons.insert(.a)
        sample.leftTrigger = 0.75
        sample.leftStickX = 0.5
        input.submitController(registration, sample: sample, capturedAt: now)
        let rearmed = try #require(backend.calls.last)
        #expect(rearmed.buttons == ControllerButtons([.a, .b]).rawValue)
        #expect(rearmed.analog.leftTrigger == 191 && rearmed.analog.leftStickX == 16384)
        #expect(rearmed.analog.rightTrigger == 0 && rearmed.analog.rightStickY == 0)
    }

    @Test func heldTouchContactRearmsIndependentlyAfterLeavingNativeControls() throws {
        let (input, backend) = rig()
        defer { input.stop() }
        let registration = try #require(input.registerController(descriptor))
        var sample = ControllerInputSample(touchpad: .init(
            primaryX: 0.4, primaryY: 0.4, secondaryX: 0, secondaryY: 0, clicked: false))
        input.submitController(registration, sample: sample, capturedAt: now)
        input.setFocused(true, suppressHeldControls: true)
        sample.touchpad?.secondaryX = -0.4
        sample.touchpad?.secondaryY = -0.4
        input.submitController(registration, sample: sample, capturedAt: now)
        #expect(backend.touches.count == 1)
        #expect(backend.touches.first?.eventType == UInt8(StreamProtocol.LI_TOUCH_EVENT_DOWN))
        let secondary = try #require(backend.touches.first?.pointerId)

        sample.touchpad?.primaryX = 0
        sample.touchpad?.primaryY = 0
        input.submitController(registration, sample: sample, capturedAt: now)
        #expect(backend.touches.count == 1)
        sample.touchpad?.primaryX = 0.4
        sample.touchpad?.primaryY = 0.4
        input.submitController(registration, sample: sample, capturedAt: now)
        #expect(backend.touches.count == 2)
        #expect(backend.touches.last?.eventType == UInt8(StreamProtocol.LI_TOUCH_EVENT_DOWN))
        #expect(backend.touches.last?.pointerId != secondary)
    }
}
