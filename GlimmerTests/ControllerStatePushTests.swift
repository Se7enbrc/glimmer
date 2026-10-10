//
//  ControllerStatePushTests.swift
//
//  The exact controller state the forwarder sends for a GameController snapshot: buttons,
//  sticks, triggers, the quit-chord hold gate, held-button sets and touchpad contacts.
//

import GameController
import Testing
@testable import Glimmer

@MainActor
struct ControllerStatePushTests {

    private struct Rig {
        let forwarder: InputForwarder
        let backend: InputRecordingBackend
        let controller: GCController
        let pad: GCExtendedGamepad
        let slot: UInt8
    }

    private func rig(chord: ControllerQuitChord = .none) throws -> Rig {
        let forwarder = InputForwarder()
        forwarder.controllerQuitChordProvider = { chord }
        let controller = GCController.withExtendedGamepad()
        let pad = try #require(controller.extendedGamepad)
        forwarder.attach(gamepad: controller)
        let slot = try #require(forwarder.attachedControllers[ObjectIdentifier(controller)]?.slot)
        let backend = InputRecordingBackend()
        forwarder.setBackend(backend)
        forwarder.isReady = true
        return Rig(forwarder: forwarder, backend: backend, controller: controller, pad: pad, slot: slot)
    }

    // MARK: - Full-state push

    @Test func fullStateCarriesButtonsSticksAndTriggersExactly() throws {
        let rig = try rig()
        defer { rig.forwarder.detach() }
        rig.pad.buttonA.setValue(1)
        rig.pad.buttonY.setValue(1)
        rig.pad.dpad.setValueForXAxis(0, yAxis: 1)
        rig.pad.rightShoulder.setValue(1)
        rig.pad.buttonMenu.setValue(1)
        rig.pad.leftTrigger.setValue(0.5)
        rig.pad.rightTrigger.setValue(1)
        rig.pad.leftThumbstick.setValueForXAxis(1, yAxis: -1)
        rig.pad.rightThumbstick.setValueForXAxis(-0.5, yAxis: 0.25)
        rig.forwarder.sendGamepadUpdate(pad: rig.pad, slot: rig.slot)

        let sent = try #require(rig.backend.calls.last)
        #expect(rig.backend.calls.count == 1)
        #expect(sent.num == Int16(rig.slot))
        #expect(sent.mask == Int16(1) << Int16(rig.slot))
        #expect(sent.buttons == StreamProtocol.A_FLAG | StreamProtocol.Y_FLAG | StreamProtocol.UP_FLAG
            | StreamProtocol.RB_FLAG | StreamProtocol.PLAY_FLAG)
        #expect(sent.analog.leftTrigger == 128)
        #expect(sent.analog.rightTrigger == 255)
        #expect(sent.analog.leftStickX == 32767)
        #expect(sent.analog.leftStickY == -32767)
        #expect(sent.analog.rightStickX == -16384)
        #expect(sent.analog.rightStickY == 8192)
    }

    @Test func nothingIsSentWhileTheStreamIsNotReady() throws {
        let rig = try rig()
        defer { rig.forwarder.detach() }
        rig.forwarder.isReady = false
        rig.pad.buttonA.setValue(1)
        rig.forwarder.sendGamepadUpdate(pad: rig.pad, slot: rig.slot)
        rig.forwarder.sendCenterButtonUpdate(pad: rig.pad, slot: rig.slot)
        #expect(rig.backend.calls.isEmpty)
    }

    @Test func centreButtonEdgePushesStateOnceWithoutTouchEvents() throws {
        let rig = try rig()
        defer { rig.forwarder.detach() }
        rig.pad.buttonB.setValue(1)
        rig.forwarder.sendCenterButtonUpdate(pad: rig.pad, slot: rig.slot)
        #expect(rig.backend.calls.map(\.buttons) == [StreamProtocol.B_FLAG])
        #expect(rig.backend.touches.isEmpty)
    }

    @Test func buttonTableMapsEveryFaceDpadAndShoulderToItsHostFlag() throws {
        let rig = try rig()
        defer { rig.forwarder.detach() }
        let pad = rig.pad
        let dpad = pad.dpad
        let table: [(Float, (Float) -> Void, Int32)] = [
            (1, pad.buttonA.setValue, StreamProtocol.A_FLAG), (1, pad.buttonB.setValue, StreamProtocol.B_FLAG),
            (1, pad.buttonX.setValue, StreamProtocol.X_FLAG), (1, pad.buttonY.setValue, StreamProtocol.Y_FLAG),
            (1, { dpad.setValueForXAxis(0, yAxis: $0) }, StreamProtocol.UP_FLAG),
            (1, { dpad.setValueForXAxis(0, yAxis: -$0) }, StreamProtocol.DOWN_FLAG),
            (1, { dpad.setValueForXAxis(-$0, yAxis: 0) }, StreamProtocol.LEFT_FLAG),
            (1, { dpad.setValueForXAxis($0, yAxis: 0) }, StreamProtocol.RIGHT_FLAG),
            (1, pad.leftShoulder.setValue, StreamProtocol.LB_FLAG),
            (1, pad.rightShoulder.setValue, StreamProtocol.RB_FLAG),
            (1, pad.buttonMenu.setValue, StreamProtocol.PLAY_FLAG)
        ]
        #expect(rig.forwarder.pressedButtonFlags(pad: pad) == 0)
        for (value, apply, flag) in table {
            apply(value)
            #expect(rig.forwarder.pressedButtonFlags(pad: pad) == flag, "flag \(flag)")
            apply(0)
        }
    }

    // MARK: - Quit chord

    @Test func heldChordIsWithheldFromTheHostAndReleaseCancelsTheDwell() throws {
        let rig = try rig(chord: .l1r1)
        defer { rig.forwarder.detach() }
        rig.pad.leftShoulder.setValue(1)
        rig.pad.rightShoulder.setValue(1)
        rig.forwarder.sendGamepadUpdate(pad: rig.pad, slot: rig.slot)
        #expect(rig.backend.calls.isEmpty)
        #expect(rig.forwarder.quitChordDwellSlot == rig.slot)
        #expect(rig.forwarder.quitChordDwellTask != nil)

        rig.pad.rightShoulder.setValue(0)
        rig.forwarder.sendGamepadUpdate(pad: rig.pad, slot: rig.slot)
        #expect(rig.backend.calls.map(\.buttons) == [StreamProtocol.LB_FLAG])
        #expect(rig.forwarder.quitChordDwellSlot == nil)
        #expect(rig.forwarder.quitChordDwellTask == nil)
    }

    @Test func chordIsOnlyEvaluatedWhenConfigured() throws {
        let rig = try rig(chord: .none)
        defer { rig.forwarder.detach() }
        rig.pad.leftShoulder.setValue(1)
        rig.pad.rightShoulder.setValue(1)
        #expect(!rig.forwarder.matchesControllerQuitChord(pad: rig.pad, buttons: rig.forwarder.pressedButtonFlags(pad: rig.pad)))
        rig.forwarder.controllerQuitChordProvider = { .l1r1 }
        #expect(rig.forwarder.matchesControllerQuitChord(pad: rig.pad, buttons: rig.forwarder.pressedButtonFlags(pad: rig.pad)))
        #expect(!rig.forwarder.matchesControllerQuitChord(buttons: StreamProtocol.LB_FLAG, leftTrigger: 0, rightTrigger: 0))
        #expect(rig.forwarder.matchesControllerQuitChord(buttons: StreamProtocol.LB_FLAG | StreamProtocol.RB_FLAG,
                                                         leftTrigger: 0, rightTrigger: 0))
    }

    @Test func triggersCountForTheChordAtAHalfPull() throws {
        let rig = try rig(chord: .l1r1l2r2)
        defer { rig.forwarder.detach() }
        rig.pad.leftShoulder.setValue(1)
        rig.pad.rightShoulder.setValue(1)
        rig.pad.leftTrigger.setValue(0.49)
        rig.pad.rightTrigger.setValue(0.5)
        let flags = rig.forwarder.pressedButtonFlags(pad: rig.pad)
        #expect(!rig.forwarder.matchesControllerQuitChord(pad: rig.pad, buttons: flags))
        rig.pad.leftTrigger.setValue(0.5)
        #expect(rig.forwarder.matchesControllerQuitChord(pad: rig.pad, buttons: flags))
        let state = rig.forwarder.quitChordState(pad: rig.pad)
        #expect(state.analog.leftTrigger == 255)
        #expect(state.analog.rightTrigger == 255)
    }

    @Test func chordStateDropsTheXboxShareFlag() throws {
        let rig = try rig()
        defer { rig.forwarder.detach() }
        let state = rig.forwarder.quitChordState(buttons: StreamProtocol.MISC_FLAG | StreamProtocol.A_FLAG, pad: rig.pad)
        #expect(state.buttons == StreamProtocol.A_FLAG)
        #expect(state.analog.leftTrigger == 0)
        #expect(state.analog.rightTrigger == 0)
    }

    @Test func centreButtonChordsAreTheOnlyOnesThatUseCentreButtons() throws {
        let rig = try rig()
        defer { rig.forwarder.detach() }
        let cases: [(ControllerQuitChord, Set<ControllerButton>, Bool)] = [
            (.startSelectL1R1, [], true), (.l1r1, [], false), (.l1r1l2r2, [], false), (.l3r3, [], false),
            (.none, [], false), (.custom, [.l1, .mute], true), (.custom, [.options], true),
            (.custom, [.ps], true), (.custom, [.l1, .r1, .touchpad], false), (.custom, [], false)
        ]
        for (chord, custom, expected) in cases {
            rig.forwarder.controllerQuitChordProvider = { chord }
            rig.forwarder.customControllerChordProvider = { custom }
            #expect(rig.forwarder.quitChordUsesCentreButtons() == expected, "\(chord) \(custom)")
        }
    }

    // MARK: - Held-button sets

    @Test func heldSetFromASnapshotNamesEachPressedButton() throws {
        let rig = try rig()
        defer { rig.forwarder.detach() }
        let pad = rig.pad
        #expect(heldControllerButtons(pad: pad).isEmpty)
        pad.buttonA.setValue(1)
        pad.dpad.setValueForXAxis(-1, yAxis: 0)
        pad.leftShoulder.setValue(1)
        pad.buttonMenu.setValue(1)
        pad.leftTrigger.setValue(0.5)
        pad.rightTrigger.setValue(0.49)
        #expect(heldControllerButtons(pad: pad) == [.faceDown, .dpadLeft, .l1, .options, .l2])
    }

    @Test func hostMaskReaderMapsEveryFlagAndTheTriggerThreshold() {
        let flags: [(Int32, ControllerButton)] = [
            (StreamProtocol.A_FLAG, .faceDown), (StreamProtocol.B_FLAG, .faceRight),
            (StreamProtocol.X_FLAG, .faceLeft), (StreamProtocol.Y_FLAG, .faceUp),
            (StreamProtocol.UP_FLAG, .dpadUp), (StreamProtocol.DOWN_FLAG, .dpadDown),
            (StreamProtocol.LEFT_FLAG, .dpadLeft), (StreamProtocol.RIGHT_FLAG, .dpadRight),
            (StreamProtocol.LB_FLAG, .l1), (StreamProtocol.RB_FLAG, .r1),
            (StreamProtocol.LS_CLK_FLAG, .l3), (StreamProtocol.RS_CLK_FLAG, .r3),
            (StreamProtocol.TOUCHPAD_FLAG, .touchpad), (StreamProtocol.PLAY_FLAG, .options),
            (StreamProtocol.BACK_FLAG, .create), (StreamProtocol.SPECIAL_FLAG, .ps),
            (StreamProtocol.MISC_FLAG, .mute)
        ]
        for (flag, button) in flags {
            #expect(heldControllerButtons(buttons: flag, leftTrigger: 0, rightTrigger: 0) == [button])
        }
        #expect(heldControllerButtons(buttons: 0, leftTrigger: 128, rightTrigger: 127) == [.l2])
        #expect(heldControllerButtons(buttons: 0, leftTrigger: 127, rightTrigger: 255) == [.r2])
    }

    // MARK: - Touchpad

    private func touchRig() -> (InputForwarder, InputRecordingBackend) {
        let forwarder = InputForwarder()
        let backend = InputRecordingBackend()
        forwarder.setBackend(backend)
        forwarder.isReady = true
        return (forwarder, backend)
    }

    private let down = UInt8(StreamProtocol.LI_TOUCH_EVENT_DOWN)
    private let move = UInt8(StreamProtocol.LI_TOUCH_EVENT_MOVE)
    private let up = UInt8(StreamProtocol.LI_TOUCH_EVENT_UP)

    @Test func fingerContactFlipsYIntoHostSpaceAndEmitsDownMoveUp() throws {
        let (forwarder, backend) = touchRig()
        defer { forwarder.detach() }
        let idle: (x: Float, y: Float) = (0, 0)
        forwarder.forwardTouchpad(slot: 2, primary: (0.5, 0.5), secondary: idle)
        forwarder.forwardTouchpad(slot: 2, primary: (0.5, 0.5), secondary: idle)
        forwarder.forwardTouchpad(slot: 2, primary: (-1, -1), secondary: idle)
        forwarder.forwardTouchpad(slot: 2, primary: idle, secondary: idle)

        let sent = backend.touches
        #expect(sent.map(\.eventType) == [down, move, up])
        #expect(sent.map(\.num) == [2, 2, 2])
        #expect(sent[0].x == 0.75 && sent[0].y == 0.25 && sent[0].pressure == 1)
        #expect(sent[1].x == 0 && sent[1].y == 1 && sent[1].pressure == 1)
        #expect(sent[2].x == 0 && sent[2].y == 1 && sent[2].pressure == 0)
        #expect(Set(sent.map(\.pointerId)).count == 1)
        #expect(sent[0].pointerId != 0)
    }

    @Test func secondFingerGetsItsOwnPointerAndLiftsIndependently() throws {
        let (forwarder, backend) = touchRig()
        defer { forwarder.detach() }
        forwarder.forwardTouchpad(slot: 0, primary: (0.1, 0.1), secondary: (0.2, 0.2))
        forwarder.forwardTouchpad(slot: 0, primary: (0.1, 0.1), secondary: (0, 0))
        let sent = backend.touches
        #expect(sent.map(\.eventType) == [down, down, up])
        #expect(sent[0].pointerId != sent[1].pointerId)
        #expect(sent[2].pointerId == sent[1].pointerId)
    }

    @Test func releasingASlotLiftsOnlyItsContactsAndNewContactsGetFreshIDs() throws {
        let (forwarder, backend) = touchRig()
        defer { forwarder.detach() }
        forwarder.forwardTouchpad(slot: 0, primary: (0.3, 0.3), secondary: (0, 0))
        forwarder.forwardTouchpad(slot: 1, primary: (0.4, 0.4), secondary: (0, 0))
        forwarder.releaseControllerTouches(slot: 0)
        #expect(backend.touches.map(\.eventType) == [down, down, up])
        #expect(backend.touches.last?.num == 0)
        forwarder.forwardTouchpad(slot: 0, primary: (0.3, 0.3), secondary: (0, 0))
        let ids = backend.touches.filter { $0.eventType == down && $0.num == 0 }.map(\.pointerId)
        #expect(ids.count == 2)
        #expect(ids[0] != ids[1])
    }

    @Test func touchpadStaysQuietWhenInputIsNotForwarded() {
        let (forwarder, backend) = touchRig()
        defer { forwarder.detach() }
        forwarder.isReady = false
        forwarder.forwardTouchpad(slot: 0, primary: (0.5, 0.5), secondary: (0, 0))
        #expect(backend.touches.isEmpty)
    }
}
