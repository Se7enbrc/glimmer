// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import AppKit
import GameController
import Testing
@testable import Glimmer

@MainActor
struct ControllerTouchpadMouseTests {
    private let idle: (x: Float, y: Float) = (0, 0)
    private let neutral = InputForwarder.neutralControllerAnalog

    private func rig() -> (InputForwarder, InputRecordingBackend) {
        let forwarder = InputForwarder()
        let backend = InputRecordingBackend()
        forwarder.setBackend(backend)
        forwarder.isReady = true
        forwarder.controllerMouseStates[0] = ControllerMouseState(isMouse: true)
        return (forwarder, backend)
    }

    @Test func gameControllerCoordinatesFlipYAndRetainTheExistingContactSentinel() {
        #expect(ControllerTouchpadMouseState.contact((1, 1)) == SIMD2<Float>(1, 0))
        #expect(ControllerTouchpadMouseState.contact((-1, -1)) == SIMD2<Float>(0, 1))
        #expect(ControllerTouchpadMouseState.contact(idle) == nil)
        #expect(ControllerTouchpadMouseState.contact((.nan, 1)) == nil)
        #expect(ControllerTouchpadMouseState.contact((1, .infinity)) == nil)
    }

    @Test func oneFingerMovesRelativelyInBothAxesAndLandingAndLiftingNeverMove() {
        var state = ControllerTouchpadMouseState()
        let landing = state.update(primary: SIMD2(0.2, 0.2), secondary: nil, clicked: false, now: 0)
        #expect(landing == .init())
        let move = state.update(primary: SIMD2(0.21, 0.21), secondary: nil, clicked: false, now: 0.02)
        #expect(move.dx > 0 && move.dy > 0 && move.dx < 20)
        #expect(move.scrollX == 0 && move.scrollY == 0)
        let lift = state.update(primary: nil, secondary: nil, clicked: false, now: 0.03)
        #expect(lift == .init())
        let reland = state.update(primary: SIMD2(0.9, 0.9), secondary: nil, clicked: false, now: 0.04)
        #expect(reland == .init())
        let reverse = state.update(primary: SIMD2(0.89, 0.89), secondary: nil, clicked: false, now: 0.06)
        #expect(reverse.dx < 0 && reverse.dy < 0)
    }

    @Test func fastSwipesGetOnlyLightAcceleration() {
        var slow = ControllerTouchpadMouseState()
        var fast = ControllerTouchpadMouseState()
        _ = slow.update(primary: SIMD2(0.2, 0.2), secondary: nil, clicked: false, now: 0)
        _ = fast.update(primary: SIMD2(0.2, 0.2), secondary: nil, clicked: false, now: 0)
        let slowMove = slow.update(primary: SIMD2(0.24, 0.2), secondary: nil, clicked: false, now: 0.1)
        let fastMove = fast.update(primary: SIMD2(0.24, 0.2), secondary: nil, clicked: false, now: 0.01)
        #expect(fastMove.dx > slowMove.dx)
        #expect(Float(fastMove.dx) < Float(slowMove.dx) * 1.35)
    }

    @Test func stationaryNoiseNeverDriftsAndSlowMovementKeepsFractionalPixels() {
        var state = ControllerTouchpadMouseState()
        _ = state.update(primary: SIMD2(0.2, 0.2), secondary: nil, clicked: false, now: 0)
        for frame in 1...1000 {
            let jitter: Float = frame.isMultiple(of: 2) ? 0.0003 : -0.0003
            let move = state.update(primary: SIMD2(0.2 + jitter, 0.2), secondary: nil,
                                    clicked: false, now: Double(frame) * 0.01)
            #expect(move == .init())
        }
        var pixels = 0
        for frame in 1...100 {
            let move = state.update(primary: SIMD2(0.2 + Float(frame) * 0.0002, 0.2), secondary: nil,
                                    clicked: false, now: 10 + Double(frame) * 0.05)
            pixels += Int(move.dx)
        }
        #expect(pixels >= 17 && pixels <= 19)
    }

    @Test func twoFingerCentroidScrollsBothAxesInWholeNotchesWithoutMovingThePointer() {
        var state = ControllerTouchpadMouseState()
        _ = state.update(primary: SIMD2(0.2, 0.2), secondary: SIMD2(0.4, 0.4), clicked: false, now: 0)
        let move = state.update(primary: SIMD2(0.41, 0.41), secondary: SIMD2(0.61, 0.61),
                                clicked: false, now: 0.02)
        #expect(move.dx == 0 && move.dy == 0)
        #expect(move.scrollX == -240 && move.scrollY == -120)
    }

    @Test func contactChangesRebasePointerAndDiscardBankedScroll() {
        var state = ControllerTouchpadMouseState()
        _ = state.update(primary: SIMD2(0.2, 0.2), secondary: nil, clicked: false, now: 0)
        let secondDown = state.update(primary: SIMD2(0.2, 0.2), secondary: SIMD2(0.8, 0.8),
                                      clicked: false, now: 0.01)
        #expect(secondDown == .init())
        let bank = state.update(primary: SIMD2(0.25, 0.2), secondary: SIMD2(0.85, 0.8),
                                clicked: false, now: 0.02)
        #expect(bank == .init())
        let primaryUp = state.update(primary: nil, secondary: SIMD2(0.85, 0.8), clicked: false, now: 0.03)
        #expect(primaryUp == .init())
        let remaining = state.update(primary: nil, secondary: SIMD2(0.86, 0.8), clicked: false, now: 0.04)
        #expect(remaining.dx > 0 && remaining.scrollX == 0)
        let swap = state.update(primary: SIMD2(0.1, 0.1), secondary: nil, clicked: false, now: 0.05)
        #expect(swap == .init())
        _ = state.update(primary: SIMD2(0.2, 0.2), secondary: SIMD2(0.4, 0.4), clicked: false, now: 0.06)
        let fresh = state.update(primary: SIMD2(0.26, 0.2), secondary: SIMD2(0.46, 0.4),
                                 clicked: false, now: 0.07)
        #expect(fresh.scrollX == 0)
    }

    @Test func clicksLatchOneOrTwoFingerChoiceUntilPhysicalRelease() {
        var state = ControllerTouchpadMouseState()
        _ = state.update(primary: SIMD2(0.2, 0.2), secondary: nil, clicked: true, now: 0)
        #expect(state.clickedButton == StreamProtocol.BUTTON_LEFT)
        _ = state.update(primary: SIMD2(0.2, 0.2), secondary: SIMD2(0.4, 0.4), clicked: true, now: 0.01)
        #expect(state.clickedButton == StreamProtocol.BUTTON_LEFT)
        _ = state.update(primary: nil, secondary: nil, clicked: false, now: 0.02)
        #expect(state.clickedButton == nil)
        _ = state.update(primary: SIMD2(0.2, 0.2), secondary: SIMD2(0.4, 0.4), clicked: true, now: 0.03)
        #expect(state.clickedButton == StreamProtocol.BUTTON_RIGHT)
        _ = state.update(primary: nil, secondary: SIMD2(0.4, 0.4), clicked: true, now: 0.04)
        #expect(state.clickedButton == StreamProtocol.BUTTON_RIGHT)
        _ = state.update(primary: nil, secondary: nil, clicked: false, now: 0.05)
        #expect(state.clickedButton == nil)
        _ = state.update(primary: nil, secondary: nil, clicked: true, now: 0.06)
        #expect(state.clickedButton == StreamProtocol.BUTTON_LEFT)
    }

    @Test func gameControllerMouseFramesStillReadTheSurfaceAndCentreEdgesDoNotRepeatIt() throws {
        let (forwarder, backend) = rig()
        defer { forwarder.detach() }
        let pad = try #require(GCController.withExtendedGamepad().extendedGamepad)
        var reads = 0
        for position: Float in [0.2, 0.3] {
            forwarder.sendGamepadUpdate(pad: pad, slot: 0) {
                reads += 1
                forwarder.forwardTouchpad(slot: 0, primary: (position, 0.2), secondary: self.idle, now: 1)
            }
        }
        forwarder.sendCenterButtonUpdate(pad: pad, slot: 0)
        #expect(reads == 2)
        #expect(backend.calls.isEmpty && backend.touches.isEmpty)
        #expect(backend.mouseMoves.count == 1)
    }

    @Test func modeGatingPreservesGameContactsAndOnlyMouseModeMovesAndScrolls() {
        let (forwarder, backend) = rig()
        defer { forwarder.detach() }
        forwarder.controllerMouseStates[0] = nil
        forwarder.forwardTouchpad(slot: 0, primary: (0.2, 0.2), secondary: idle, clicked: true)
        #expect(backend.touches.count == 1 && backend.pointer.isEmpty && backend.mouseMoves.isEmpty)
        toggle(forwarder)
        #expect(backend.touches.last?.eventType == UInt8(StreamProtocol.LI_TOUCH_EVENT_UP))
        forwarder.forwardTouchpad(slot: 0, primary: (0.2, 0.2), secondary: idle, now: 1)
        forwarder.forwardTouchpad(slot: 0, primary: (0.3, 0.2), secondary: idle, now: 1.02)
        #expect(backend.mouseMoves.count == 1 && backend.touches.count == 2)
        forwarder.forwardTouchpad(slot: 0, primary: (0.2, 0.2), secondary: (0.4, 0.4), now: 1.03)
        forwarder.forwardTouchpad(slot: 0, primary: (0.85, 0.85), secondary: (1, 1), now: 1.04)
        #expect(backend.pointer.contains(.scroll(120)))
        #expect(backend.pointer.contains(.hScroll(-360)))
        toggle(forwarder)
        forwarder.forwardTouchpad(slot: 0, primary: (0.2, 0.2), secondary: idle)
        #expect(backend.touches.count == 3 && backend.mouseMoves.count == 1)
    }

    private func toggle(_ forwarder: InputForwarder) {
        forwarder.routeControllerMouse(slot: 0, buttons: StreamProtocol.PLAY_FLAG,
                                       analog: neutral, chordHeld: false, now: 10)
        forwarder.routeControllerMouse(slot: 0, buttons: 0, analog: neutral, chordHeld: false, now: 11)
    }

    @Test(arguments: ["toggle", "detach", "focus", "end", "reconnect", "chord"])
    func lifecycleReleasesTouchpadClicksAndRebasesMotion(action: String) {
        let (forwarder, backend) = rig()
        defer { forwarder.detach() }
        let controller = GCController.withExtendedGamepad()
        if action == "detach" { forwarder.attach(gamepad: controller) }
        forwarder.forwardTouchpad(slot: 0, primary: (0.2, 0.2), secondary: idle, clicked: true)
        switch action {
        case "toggle": toggle(forwarder)
        case "detach": forwarder.detach(gamepad: controller)
        case "focus": forwarder.neutralizeControllers()
        case "end": forwarder.detach()
        case "reconnect": forwarder.setReady(false)
        default:
            forwarder.routeControllerMouse(slot: 0, buttons: 0, analog: neutral, chordHeld: true)
        }
        #expect(backend.pointer == [
            .button(action: Int8(StreamProtocol.BUTTON_ACTION_PRESS), button: StreamProtocol.BUTTON_LEFT),
            .button(action: Int8(StreamProtocol.BUTTON_ACTION_RELEASE), button: StreamProtocol.BUTTON_LEFT)
        ])
        forwarder.isReady = true
        forwarder.forwardTouchpad(slot: 0, primary: (0.8, 0.8), secondary: idle)
        #expect(backend.mouseMoves.isEmpty)
    }

    @Test func faceButtonAndPhysicalMouseKeepOwnershipAfterTouchpadRelease() {
        let (forwarder, backend) = rig()
        defer { forwarder.detach() }
        forwarder.forwardTouchpad(slot: 0, primary: (0.2, 0.2), secondary: idle, clicked: true)
        forwarder.routeControllerMouse(slot: 0, buttons: StreamProtocol.A_FLAG, analog: neutral, chordHeld: false)
        forwarder.forwardTouchpad(slot: 0, primary: idle, secondary: idle)
        #expect(backend.pointer.count == 1)
        forwarder.updatePhysicalMouseButton(StreamProtocol.BUTTON_LEFT, pressed: true)
        forwarder.routeControllerMouse(slot: 0, buttons: 0, analog: neutral, chordHeld: false)
        #expect(backend.pointer.count == 1)
        forwarder.updatePhysicalMouseButton(StreamProtocol.BUTTON_LEFT, pressed: false)
        #expect(backend.pointer.count == 2)
    }

    @Test func twoFingerClickUsesRightButtonAndPadsKeepIndependentOwnership() {
        let (forwarder, backend) = rig()
        defer { forwarder.detach() }
        forwarder.controllerMouseStates[1] = ControllerMouseState(isMouse: true)
        for slot: UInt8 in [0, 1] {
            forwarder.forwardTouchpad(slot: slot, primary: (0.2, 0.2), secondary: (0.4, 0.4), clicked: true)
        }
        forwarder.resetControllerMouse(slot: 0)
        #expect(backend.pointer == [
            .button(action: Int8(StreamProtocol.BUTTON_ACTION_PRESS), button: StreamProtocol.BUTTON_RIGHT)
        ])
        forwarder.forwardTouchpad(slot: 1, primary: idle, secondary: idle)
        #expect(backend.pointer.last ==
            .button(action: Int8(StreamProtocol.BUTTON_ACTION_RELEASE), button: StreamProtocol.BUTTON_RIGHT))
    }

    @Test func readinessFocusAndStopChordGateTouchpadSnapshots() throws {
        let (forwarder, backend) = rig()
        defer { forwarder.detach() }
        let window = NSWindow()
        forwarder.window = window
        forwarder.forwardTouchpad(slot: 0, primary: (0.2, 0.2), secondary: idle, clicked: true)
        forwarder.isMiniPlayer = true
        forwarder.isReady = false
        forwarder.forwardTouchpad(slot: 0, primary: (0.3, 0.2), secondary: idle, clicked: true)
        forwarder.isReady = true
        forwarder.quitChordDwellSlot = 0
        forwarder.forwardTouchpad(slot: 0, primary: (0.4, 0.2), secondary: idle, clicked: true)
        let pad = try #require(GCController.withExtendedGamepad().extendedGamepad)
        forwarder.controllerQuitChordProvider = { .l1r1 }
        pad.leftShoulder.setValue(1)
        pad.rightShoulder.setValue(1)
        var reads = 0
        forwarder.sendGamepadUpdate(pad: pad, slot: 0) { reads += 1 }
        #expect(reads == 0)
        #expect(backend.touches.isEmpty && backend.mouseMoves.isEmpty && backend.pointer.isEmpty)
        forwarder.quitChordDwellSlot = nil
        _ = forwarder.inputCore.withLock { forwarder.inputCore.chordSlots.remove(0) }
        forwarder.forwardTouchpad(slot: 0, primary: (0.5, 0.2), secondary: idle, clicked: true)
        #expect(backend.pointer.count == 1)
    }
}
