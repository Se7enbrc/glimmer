// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import AppKit
import GameController
import Testing
@testable import Glimmer

@MainActor
struct ControllerMouseTests {
    private let start = StreamProtocol.PLAY_FLAG
    private let neutral = InputForwarder.neutralControllerAnalog
    private var primary: GamepadAnalog {
        var value = neutral
        value.rightTrigger = 255
        return value
    }

    private func rig() -> (InputForwarder, InputRecordingBackend) {
        let forwarder = InputForwarder()
        let backend = InputRecordingBackend()
        forwarder.setBackend(backend)
        forwarder.isReady = true
        forwarder.gamepadMask = 3
        return (forwarder, backend)
    }

    private func toggle(_ forwarder: InputForwarder, slot: UInt8 = 0, now: TimeInterval = 10) {
        forwarder.routeControllerMouse(slot: slot, buttons: start, analog: neutral, chordHeld: false, now: now)
        forwarder.routeControllerMouse(slot: slot, buttons: 0, analog: neutral, chordHeld: false, now: now + 0.751)
    }

    @Test func idleMouseModeSleepsAndMovementRearmsPolling() {
        let (forwarder, backend) = rig()
        defer { forwarder.detach() }
        toggle(forwarder)
        #expect(forwarder.controllerMouseStates[0]?.isMouse == true)
        #expect(forwarder.controllerMouseTask == nil)
        var analog = neutral
        analog.rightStickX = 30_000
        forwarder.routeControllerMouse(slot: 0, buttons: 0, analog: analog, chordHeld: false)
        #expect(forwarder.controllerMouseTask != nil)
        forwarder.pollControllerMouse()
        #expect(!backend.mouseMoves.isEmpty)
        forwarder.routeControllerMouse(slot: 0, buttons: 0, analog: neutral, chordHeld: false)
        #expect(forwarder.controllerMouseTask == nil)
        analog.rightStickY = 30_000
        forwarder.routeControllerMouse(slot: 0, buttons: 0, analog: analog, chordHeld: false)
        #expect(forwarder.controllerMouseTask != nil)
    }

    @Test func togglesOnlyOnReleaseAfterMoonlightsThreshold() {
        var state = ControllerMouseState()
        let toggled1 = state.update(buttons: start, analog: neutral, chordHeld: false, now: 0)
        #expect(!toggled1)
        let toggled2 = state.update(buttons: start, analog: neutral, chordHeld: false, now: 1)
        #expect(!toggled2)
        #expect(!state.isMouse)
        let toggled3 = state.update(buttons: 0, analog: neutral, chordHeld: false, now: 1)
        #expect(toggled3)
        #expect(state.isMouse)
        let toggled4 = state.update(buttons: 0, analog: neutral, chordHeld: false, now: 2)
        #expect(!toggled4)
        let toggled5 = state.update(buttons: start, analog: neutral, chordHeld: false, now: 3)
        #expect(!toggled5)
        let toggled6 = state.update(buttons: 0, analog: neutral, chordHeld: false, now: 4)
        #expect(toggled6)
        #expect(!state.isMouse)
    }

    @Test(arguments: [0.0, 0.1, 0.749, 0.75])
    func shortPressDoesNotToggle(duration: Double) {
        var state = ControllerMouseState()
        _ = state.update(buttons: start, analog: neutral, chordHeld: false, now: 0)
        let toggled7 = state.update(buttons: 0, analog: neutral, chordHeld: false, now: duration)
        #expect(!toggled7)
        #expect(!state.isMouse)
    }

    @Test func homeAndOtherButtonsSpendTheWholeStartHold() {
        for flag in [StreamProtocol.SPECIAL_FLAG, StreamProtocol.BACK_FLAG, StreamProtocol.A_FLAG] {
            var state = ControllerMouseState()
            _ = state.update(buttons: start, analog: neutral, chordHeld: false, now: 0)
            _ = state.update(buttons: start | flag, analog: neutral, chordHeld: false, now: 0.1)
            _ = state.update(buttons: start, analog: neutral, chordHeld: false, now: 0.2)
            let toggled8 = state.update(buttons: 0, analog: neutral, chordHeld: false, now: 1)
            #expect(!toggled8)
            #expect(!state.isMouse)
        }
        var state = ControllerMouseState()
        _ = state.update(buttons: StreamProtocol.SPECIAL_FLAG, analog: neutral, chordHeld: false, now: 0)
        let toggled9 = state.update(buttons: 0, analog: neutral, chordHeld: false, now: 2)
        #expect(!toggled9)
    }

    @Test func mouseRoutingAndPollingStayQuietBeforeInputIsReady() {
        let (forwarder, backend) = rig()
        defer { forwarder.detach() }
        forwarder.isReady = false
        toggle(forwarder)
        forwarder.pollControllerMouse()
        #expect(forwarder.controllerMouseStates.isEmpty)
        #expect(backend.calls.isEmpty && backend.pointer.isEmpty && backend.mouseMoves.isEmpty)
    }

    @Test func cancelledQuitChordCannotBecomeAMouseToggle() {
        let (forwarder, backend) = rig()
        defer { forwarder.detach() }
        forwarder.controllerQuitChordProvider = { .startSelectL1R1 }
        let chord = start | StreamProtocol.BACK_FLAG | StreamProtocol.LB_FLAG | StreamProtocol.RB_FLAG
        forwarder.pushHID(slot: 0, state: (start, neutral)) { (start, self.neutral) }
        forwarder.pushHID(slot: 0, state: (chord, neutral)) { (chord, self.neutral) }
        #expect(forwarder.inputCore.layouts?.states[0]?.gesture.deadline != nil)
        forwarder.pushHID(slot: 0, state: (start, neutral)) { (start, self.neutral) }
        #expect(forwarder.inputCore.layouts?.states[0]?.gesture.deadline == nil)
        forwarder.routeControllerMouse(slot: 0, buttons: 0, analog: neutral, chordHeld: false, now: .infinity)
        #expect(forwarder.controllerMouseStates[0]?.isMouse == false)
        #expect(backend.calls.last?.buttons == start)
    }

    @Test func customStartChordWinsAndStillStopsInMouseMode() {
        let (forwarder, _) = rig()
        defer { forwarder.detach() }
        toggle(forwarder)
        forwarder.controllerQuitChordProvider = { .custom }
        forwarder.customControllerChordProvider = { [.options] }
        var stopped = false
        forwarder.onQuitHotkey = { stopped = true }
        forwarder.pushHID(slot: 0, state: (start, neutral)) { (self.start, self.neutral) }
        #expect(forwarder.quitChordDwellSlot == 0)
        forwarder.quitChordDwellTask?.cancel()
        forwarder.controllerChordDwell.expire()
        #expect(stopped)
        forwarder.routeControllerMouse(slot: 0, buttons: 0, analog: neutral, chordHeld: false, now: .infinity)
        #expect(forwarder.controllerMouseStates[0]?.isMouse == true)
    }

    @Test(arguments: [ControllerQuitChord.l1r1, .l1r1l2r2, .l3r3])
    func everyStopPresetInterruptsStartAndMouseMotion(chord: ControllerQuitChord) {
        let (forwarder, backend) = rig()
        defer { forwarder.detach() }
        toggle(forwarder)
        forwarder.controllerQuitChordProvider = { chord }
        let buttons = start | StreamProtocol.LB_FLAG | StreamProtocol.RB_FLAG
            | StreamProtocol.LS_CLK_FLAG | StreamProtocol.RS_CLK_FLAG
        let analog = GamepadAnalog(leftTrigger: 255, rightTrigger: 255, leftStickX: 32767, leftStickY: 0,
                                   rightStickX: 0, rightStickY: 32767)
        forwarder.pushHID(slot: 0, state: (buttons, analog)) { (buttons, analog) }
        #expect(forwarder.quitChordDwellSlot == 0)
        forwarder.pollControllerMouse()
        #expect(backend.mouseMoves.isEmpty)
        #expect(backend.pointer.isEmpty)
        forwarder.pushHID(slot: 0, state: (0, neutral)) { (0, self.neutral) }
        #expect(forwarder.quitChordDwellSlot == nil)
        #expect(forwarder.controllerMouseStates[0]?.isMouse == true)
    }

    @Test func bothInputRoutesKeepShortStartPressesAndSuppressPadsInMouseMode() throws {
        let (forwarder, backend) = rig()
        defer { forwarder.detach() }
        forwarder.pushHID(slot: 0, state: (start, neutral)) { (self.start, self.neutral) }
        forwarder.pushHID(slot: 0, state: (0, neutral)) { (0, self.neutral) }
        #expect(backend.calls.map(\.buttons) == [start, 0])
        toggle(forwarder)
        let count = backend.calls.count
        forwarder.pushHID(slot: 0, state: (StreamProtocol.A_FLAG, neutral)) { (0, self.neutral) }
        #expect(backend.calls.count == count)
        let controller = GCController.withExtendedGamepad()
        let pad = try #require(controller.extendedGamepad)
        pad.rightShoulder.setValue(1)
        forwarder.sendGamepadUpdate(pad: pad, slot: 0)
        #expect(backend.calls.count == count)
        let rightClick = PointerSend.button(action: Int8(StreamProtocol.BUTTON_ACTION_PRESS),
                                           button: StreamProtocol.BUTTON_RIGHT)
        #expect(backend.pointer.contains(rightClick))
    }

    @Test func mouseMappingAndToastsArePositionalAndIndependentPerSlot() {
        let (forwarder, backend) = rig()
        defer { forwarder.detach() }
        var notifications: [String] = []
        forwarder.onControllerMouseChanged = { notifications.append($0) }
        toggle(forwarder)
        #expect(backend.calls.last?.buttons == 0)
        #expect(backend.calls.last?.analog.leftStickX == 0)
        let clicks: [(Int32, Int32)] = [
            (StreamProtocol.RS_CLK_FLAG, StreamProtocol.BUTTON_MIDDLE),
            (StreamProtocol.LB_FLAG, StreamProtocol.BUTTON_X2),
            (StreamProtocol.RB_FLAG, StreamProtocol.BUTTON_RIGHT)
        ]
        for (flag, button) in clicks {
            let count = backend.pointer.count
            forwarder.routeControllerMouse(slot: 0, buttons: flag, analog: neutral, chordHeld: false)
            forwarder.routeControllerMouse(slot: 0, buttons: 0, analog: neutral, chordHeld: false)
            #expect(Array(backend.pointer.dropFirst(count)) == [
                .button(action: Int8(StreamProtocol.BUTTON_ACTION_PRESS), button: button),
                .button(action: Int8(StreamProtocol.BUTTON_ACTION_RELEASE), button: button)
            ])
        }
        forwarder.pushHID(slot: 1, state: (StreamProtocol.Y_FLAG, neutral)) { (0, self.neutral) }
        #expect(backend.calls.last?.num == 1)
        #expect(backend.calls.last?.buttons == StreamProtocol.Y_FLAG)
        toggle(forwarder, now: 20)
        #expect(notifications == ["Controller 1 is now a mouse.",
                                  "Controller 1 is back in the game."])
    }

    @Test func unchangedClicksAndNormalGamepadFramesSkipMouseButtonWork() {
        let (forwarder, backend) = rig()
        defer { forwarder.detach() }
        #expect(!forwarder.updateControllerMouseClicks(slot: 0, clicks: []))
        forwarder.routeControllerMouse(slot: 0, buttons: 0,
                                       analog: primary, chordHeld: false)
        #expect(forwarder.controllerMouseStates[0]?.clicks.isEmpty == true)
        #expect(backend.pointer.isEmpty)
        toggle(forwarder)
        let clicks: Set<Int32> = [StreamProtocol.BUTTON_LEFT]
        let changed = forwarder.updateControllerMouseClicks(slot: 0, clicks: clicks)
        #expect(changed)
        #expect(!forwarder.updateControllerMouseClicks(slot: 0, clicks: clicks))
        #expect(backend.pointer.count == 1)
        #expect(forwarder.updateControllerMouseClicks(slot: 0, clicks: []))
        #expect(!forwarder.updateControllerMouseClicks(slot: 0, clicks: []))
        #expect(backend.pointer.count == 2)
    }

    @Test func mouseToastNamesThePadOnlyWhenMoreThanOneIsConnected() throws {
        let (forwarder, _) = rig()
        defer { forwarder.detach() }
        let controller = GCController.withExtendedGamepad()
        forwarder.attach(gamepad: controller)
        let attached = try #require(forwarder.attachedControllers[ObjectIdentifier(controller)])
        let name = controller.vendorName ?? controller.productCategory
        #expect(forwarder.controllerMouseMessage(enabled: true, slot: attached.slot)
            == "\(name) is now a mouse.")
        #expect(forwarder.controllerMouseMessage(enabled: false, slot: attached.slot)
            == "\(name) is back in the game.")
        forwarder.gamepadMask = 1 << attached.slot
        #expect(forwarder.controllerMouseMessage(enabled: true, slot: attached.slot)
            == "Controller is now a mouse.")
        #expect(forwarder.controllerMouseMessage(enabled: false, slot: attached.slot)
            == "Controller is back in the game.")
    }

    @Test func stickPollingMovesRightStickAndScrollsLeftStickUntilNeutral() {
        let (forwarder, backend) = rig()
        defer { forwarder.detach() }
        toggle(forwarder)
        let analog = GamepadAnalog(leftTrigger: 0, rightTrigger: 0, leftStickX: 32767, leftStickY: 32767,
                                   rightStickX: -32767, rightStickY: 32767)
        forwarder.routeControllerMouse(slot: 0, buttons: 0, analog: analog, chordHeld: false)
        forwarder.pollControllerMouse()
        forwarder.pollControllerMouse()
        #expect(backend.mouseMoves == [.init(dx: -62, dy: -62), .init(dx: -62, dy: -62)])
        #expect(backend.pointer == [.scroll(62), .hScroll(62), .scroll(62), .hScroll(62)])
        forwarder.routeControllerMouse(slot: 0, buttons: 0, analog: neutral, chordHeld: false)
        forwarder.pollControllerMouse()
        #expect(backend.mouseMoves.count == 2)
        #expect(InputForwarder.controllerMouseDelta(1000) == 0)
        #expect(InputForwarder.controllerMouseDelta(-32768) == -62)
    }

    @Test func unboundFaceAndDirectionalButtonsNeverClickOrScroll() {
        let (forwarder, backend) = rig()
        defer { forwarder.detach() }
        toggle(forwarder)
        let ignored = StreamProtocol.A_FLAG | StreamProtocol.B_FLAG | StreamProtocol.X_FLAG | StreamProtocol.Y_FLAG
            | StreamProtocol.UP_FLAG | StreamProtocol.DOWN_FLAG | StreamProtocol.LEFT_FLAG | StreamProtocol.RIGHT_FLAG
            | StreamProtocol.BACK_FLAG | StreamProtocol.SPECIAL_FLAG | StreamProtocol.MISC_FLAG
        forwarder.routeControllerMouse(slot: 0, buttons: ignored, analog: neutral, chordHeld: false)
        #expect(backend.pointer.isEmpty)
    }

    @Test func physicalMouseAndTwoPadsShareClickOwnershipAndDetachReleases() {
        let (forwarder, backend) = rig()
        defer { forwarder.detach() }
        toggle(forwarder)
        toggle(forwarder, slot: 1)
        forwarder.routeControllerMouse(slot: 0, buttons: 0, analog: primary, chordHeld: false)
        forwarder.routeControllerMouse(slot: 1, buttons: 0, analog: primary, chordHeld: false)
        forwarder.updatePhysicalMouseButton(StreamProtocol.BUTTON_LEFT, pressed: true)
        forwarder.resetControllerMouse(slot: 0)
        forwarder.resetControllerMouse(slot: 1)
        #expect(backend.pointer.count == 1)
        forwarder.updatePhysicalMouseButton(StreamProtocol.BUTTON_LEFT, pressed: false)
        #expect(backend.pointer == [
            .button(action: Int8(StreamProtocol.BUTTON_ACTION_PRESS), button: StreamProtocol.BUTTON_LEFT),
            .button(action: Int8(StreamProtocol.BUTTON_ACTION_RELEASE), button: StreamProtocol.BUTTON_LEFT)
        ])
        #expect(forwarder.controllerMouseTask == nil)
    }

    @Test func focusAndReconnectReleaseClicksCancelHoldsAndKeepMode() {
        let (forwarder, backend) = rig()
        defer { forwarder.detach() }
        toggle(forwarder)
        forwarder.routeControllerMouse(slot: 0, buttons: 0, analog: primary, chordHeld: false)
        forwarder.neutralizeControllers()
        let release = PointerSend.button(action: Int8(StreamProtocol.BUTTON_ACTION_RELEASE),
                                         button: StreamProtocol.BUTTON_LEFT)
        #expect(backend.pointer.last == release)
        #expect(forwarder.controllerMouseStates[0]?.isMouse == true)
        #expect(forwarder.controllerMouseTask == nil)
        forwarder.routeControllerMouse(slot: 0, buttons: start, analog: neutral, chordHeld: false, now: 30)
        forwarder.setReady(false)
        forwarder.isReady = true
        forwarder.routeControllerMouse(slot: 0, buttons: 0, analog: neutral, chordHeld: false, now: 40)
        #expect(forwarder.controllerMouseStates[0]?.isMouse == true)
        forwarder.detach()
        #expect(forwarder.controllerMouseStates.isEmpty)
        #expect(forwarder.controllerMouseTask == nil)
    }

    @Test func reconciliationRepairsAMissedMouseModeButtonRelease() throws {
        let (forwarder, backend) = rig()
        let controller = GCController.withExtendedGamepad()
        forwarder.attach(gamepad: controller)
        defer { forwarder.detach() }
        let state = try #require(forwarder.attachedControllers[ObjectIdentifier(controller)])
        toggle(forwarder, slot: state.slot)
        forwarder.routeControllerMouse(slot: state.slot, buttons: 0,
                                       analog: primary, chordHeld: false)
        forwarder.reconcileControllerButtons()
        #expect(backend.pointer.suffix(2) == [
            .button(action: Int8(StreamProtocol.BUTTON_ACTION_PRESS), button: StreamProtocol.BUTTON_LEFT),
            .button(action: Int8(StreamProtocol.BUTTON_ACTION_RELEASE), button: StreamProtocol.BUTTON_LEFT)
        ])
    }

    @Test func modeToastReusesTheStreamPillAndAnnouncesEachChange() {
        let window = StreamWindow()
        defer { window.close() }
        var announcements: [String] = []
        window.leaveHintBanner.announce = { announcements.append($0) }
        window.showStreamToast("Leave hint", for: 5)
        let generation = window.streamToastGeneration
        let mouse = "Controller is now a mouse."
        let game = "Controller is back in the game."
        window.showControllerMouseMode(mouse)
        #expect(window.leaveHintBanner.displayedText == mouse)
        #expect(window.streamToastGeneration > generation)
        window.showControllerMouseMode(game)
        #expect(window.leaveHintBanner.displayedText == game)
        #expect(announcements == ["Leave hint", mouse, game])
    }
}
