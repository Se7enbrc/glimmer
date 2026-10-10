// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  ControllerArrivalTests.swift
//
//  What a controller arrival promises the PC, how the slots it announced are kept honest across a
//  reconnect (Sunshine still holds the last session's virtual pads), what focus loss releases,
//  and what a session leaves behind when it ends.
//

import AppKit
import GameController
import Testing
@testable import Glimmer

@MainActor
struct ControllerArrivalTests {

    private typealias Arrival = InputForwarder.ControllerArrival

    @Test func touchContactsEndOnFocusLossAndRestartWithNewIDsInMiniPlayer() throws {
        let forwarder = InputForwarder()
        defer { forwarder.detach() }
        let window = ControllerFocusTestWindow()
        window.focused = true
        forwarder.attach(to: window)
        forwarder.isReady = true
        let backend = InputRecordingBackend()
        forwarder.setBackend(backend)
        let primary: (Float, Float) = (0.5, -0.25)
        let secondary: (Float, Float) = (-0.5, 0.25)
        forwarder.forwardTouchpad(slot: 0, primary: primary, secondary: secondary)
        let original = backend.touches
        #expect(original.count == 2)
        #expect(original.allSatisfy { $0.eventType == UInt8(StreamProtocol.LI_TOUCH_EVENT_DOWN) })

        window.focused = false
        forwarder.windowResignedKey()
        #expect(backend.touches.suffix(2).allSatisfy { $0.eventType == UInt8(StreamProtocol.LI_TOUCH_EVENT_UP) })
        #expect(backend.touches.suffix(2).map(\.pointerId) == original.map(\.pointerId))
        #expect(forwarder.touchpadStates.isEmpty)
        let afterRelease = backend.touches.count
        forwarder.forwardTouchpad(slot: 0, primary: primary, secondary: secondary)
        #expect(backend.touches.count == afterRelease)

        forwarder.setMiniPlayer(true)
        forwarder.forwardTouchpad(slot: 0, primary: primary, secondary: secondary)
        #expect(backend.touches.suffix(2).allSatisfy { $0.eventType == UInt8(StreamProtocol.LI_TOUCH_EVENT_DOWN) })
        #expect(Set(backend.touches.suffix(2).map(\.pointerId)).isDisjoint(with: original.map(\.pointerId)))
        let inMiniPlayer = backend.touches.count
        forwarder.windowResignedKey()
        #expect(backend.touches.count == inMiniPlayer)
        forwarder.setMiniPlayer(false)
        #expect(backend.touches.count == inMiniPlayer + 2)
        #expect(backend.touches.suffix(2).allSatisfy { $0.eventType == UInt8(StreamProtocol.LI_TOUCH_EVENT_UP) })
    }

    @Test(arguments: [false, true])
    func controllerTouchesRetireOnConnectionLossOrTeardown(teardown: Bool) {
        let forwarder = InputForwarder()
        defer { forwarder.detach() }
        let backend = InputRecordingBackend()
        forwarder.setBackend(backend)
        forwarder.isReady = true
        forwarder.forwardTouchpad(slot: 0, primary: (0.5, 0.5), secondary: (0, 0))
        if teardown { forwarder.detach() } else { forwarder.setReady(false) }
        #expect(forwarder.touchpadStates.isEmpty)
        #expect(backend.touches.count == 2)
        #expect(backend.touches.last?.eventType == UInt8(StreamProtocol.LI_TOUCH_EVENT_UP))
        #expect(backend.touches.last?.pressure == 0)
        forwarder.forwardTouchpad(slot: 0, primary: (0.75, 0.5), secondary: (0, 0))
        #expect(backend.touches.count == 2)
    }

    @Test func miniPlayerKeepsRumbleWhenTheAppIsInactiveWithoutBypassingStreamTeardown() {
        var gate = ControllerHaptics.ActivationGate(appActive: false)
        let owner = UUID()
        #expect(gate.shouldSuspend)
        gate.backgroundPlayers.insert(owner)
        #expect(!gate.shouldSuspend)
        var motors = 0
        let actions = ControllerHaptics.DrainActions(light: { _, _ in }, playerLEDs: { _, _ in },
                                                     hidRumble: { _, _ in motors += 1 },
                                                     rumble: { _, _ in motors += 1 }, triggers: { _, _ in motors += 1 })
        var drain = ControllerHaptics.PendingDrain(rumble: [0: (10, 20)], submittedAt: [:],
                                                   triggers: [0: (30, 40)], lights: [:], playerLEDs: [:],
                                                   gameControllerSlots: [], suspended: gate.shouldSuspend, quiesced: false)
        ControllerHaptics.processDrain(drain, actions: actions)
        #expect(motors == 3)
        gate.appActive = true
        gate.appActive = false
        #expect(!gate.shouldSuspend)
        drain.quiesced = true
        ControllerHaptics.processDrain(drain, actions: actions)
        #expect(motors == 3)
        gate.backgroundPlayers.remove(owner)
        drain.suspended = gate.shouldSuspend
        drain.quiesced = false
        ControllerHaptics.processDrain(drain, actions: actions)
        #expect(motors == 3)
    }

    @Test func miniPlayerKeepsHeldControllerInputWhileKeyboardAndMouseRelease() throws {
        let forwarder = InputForwarder()
        defer { forwarder.detach() }
        let window = ControllerFocusTestWindow()
        forwarder.attach(to: window)
        forwarder.setWindowMode(true)
        let pad = GCController.withExtendedGamepad()
        let gamepad = try #require(pad.extendedGamepad)
        gamepad.buttonA.setValue(1)
        forwarder.attach(gamepad: pad)
        let slot = try #require(forwarder.attachedControllers[ObjectIdentifier(pad)]?.slot)
        let backend = InputRecordingBackend()
        forwarder.setBackend(backend)
        forwarder.isReady = true
        forwarder.sendGamepadUpdate(pad: gamepad, slot: slot)
        #expect(backend.calls.isEmpty)

        forwarder.setMiniPlayer(true)
        #expect(backend.calls.last?.buttons == StreamProtocol.A_FLAG)
        let beforeFocusLoss = backend.calls.count
        forwarder.heldKeys = [0x57]
        forwarder.heldMouseButtons = [StreamProtocol.BUTTON_LEFT]
        forwarder.windowResignedKey()
        #expect(backend.calls.count == beforeFocusLoss)
        #expect(forwarder.heldKeys.isEmpty)
        #expect(forwarder.heldMouseButtons.isEmpty)
        #expect(!forwarder.forwardsMouseEvents)
        forwarder.sendGamepadUpdate(pad: gamepad, slot: slot)
        #expect(backend.calls.count == beforeFocusLoss + 1)
        #expect(backend.calls.last?.buttons == StreamProtocol.A_FLAG)

        forwarder.setMiniPlayer(false)
        let released = try #require(backend.calls.last)
        #expect(released.buttons == 0)
        #expect(UInt16(bitPattern: released.mask) & (UInt16(1) << slot) != 0)
        let afterExit = backend.calls.count
        forwarder.sendGamepadUpdate(pad: gamepad, slot: slot)
        #expect(backend.calls.count == afterExit)
        window.focused = true
        forwarder.resyncControllers()
        #expect(backend.calls.last?.buttons == StreamProtocol.A_FLAG)
    }

    @Test func miniPlayerBackgroundDeliveryTracksConnectionAndTeardown() {
        let prior = GCController.shouldMonitorBackgroundEvents
        defer { GCController.shouldMonitorBackgroundEvents = prior }
        GCController.shouldMonitorBackgroundEvents = false
        let forwarder = InputForwarder()
        defer { forwarder.detach() }
        forwarder.setMiniPlayer(true)
        #expect(!GCController.shouldMonitorBackgroundEvents)
        forwarder.setReady(true)
        #expect(GCController.shouldMonitorBackgroundEvents)
        forwarder.setReady(false)
        #expect(!GCController.shouldMonitorBackgroundEvents)
        forwarder.setReady(true)
        #expect(GCController.shouldMonitorBackgroundEvents)
        forwarder.detach()
        #expect(!GCController.shouldMonitorBackgroundEvents)
        #expect(!forwarder.isMiniPlayer)
        forwarder.setReady(true)
        #expect(!GCController.shouldMonitorBackgroundEvents)
    }

    @Test func miniPlayerPreservesQuitDwellUntilControllerOwnershipEnds() {
        let forwarder = InputForwarder()
        defer { forwarder.detach() }
        let window = ControllerFocusTestWindow()
        forwarder.attach(to: window)
        forwarder.isReady = true
        forwarder.setMiniPlayer(true)
        forwarder.controllerQuitChordProvider = { .l1r1 }
        forwarder.armQuitChordDwell(slot: 0) {
            (StreamProtocol.LB_FLAG | StreamProtocol.RB_FLAG, InputForwarder.neutralControllerAnalog)
        }
        forwarder.windowResignedKey()
        #expect(forwarder.quitChordDwellTask != nil)
        forwarder.setMiniPlayer(false)
        #expect(forwarder.quitChordDwellTask == nil)
    }

    /// Detach removes observers before a new pad can attach during stop.
    @Test func detachRemovesGamepadObservers() {
        let forwarder = InputForwarder()
        forwarder.detach()
        #expect(forwarder.connectObserver == nil)
        #expect(forwarder.disconnectObserver == nil)
    }

    /// Input before the stream is ready must not leave a deliver stamp.
    @Test func unreadyPadDoesNotStampInputDelivery() throws {
        let forwarder = InputForwarder()
        defer { forwarder.detach() }
        let pad = GCController.withExtendedGamepad()
        forwarder.attach(gamepad: pad)
        let slot = try #require(forwarder.attachedControllers[ObjectIdentifier(pad)]?.slot)
        let ex = try #require(pad.extendedGamepad)
        let handler = try #require(ex.valueChangedHandler)
        _ = InputDeliverStamp.shared.take(slot: Int(slot))
        handler(ex, ex.buttonA)
        #expect(InputDeliverStamp.shared.take(slot: Int(slot)) == 0)
    }

    /// Detach clears the stream's handler from a connected pad.
    @Test func detachClearsGamepadHandler() {
        let forwarder = InputForwarder()
        let pad = GCController.withExtendedGamepad()
        forwarder.attach(gamepad: pad)
        let installed = pad.extendedGamepad?.valueChangedHandler != nil
        forwarder.detach()
        #expect(installed)
        #expect(pad.extendedGamepad?.valueChangedHandler == nil)
    }

    @Test(arguments: [false, true])
    func leavingStreamRestoresControllerSystemState(sessionEnded: Bool) throws {
        let forwarder = InputForwarder()
        defer { forwarder.detach() }
        let pad = GCController.withExtendedGamepad()
        pad.playerIndex = .index4
        let options = pad.extendedGamepad?.buttonOptions
        let home = pad.physicalInputProfile.buttons[GCInputButtonHome]
        options?.preferredSystemGestureState = .enabled
        home?.preferredSystemGestureState = .enabled
        forwarder.attach(gamepad: pad)
        let state = try #require(forwarder.attachedControllers[ObjectIdentifier(pad)])
        #expect(state.priorPlayerIndex == .index4)
        #expect(state.priorOptionsGesture == options.map { _ in .enabled })
        #expect(pad.playerIndex != .index4)
        options?.preferredSystemGestureState = .disabled
        if #available(macOS 27, *) { home?.preferredSystemGestureState = .disabled }

        if sessionEnded { forwarder.detach() } else { forwarder.detach(gamepad: pad) }

        #expect(pad.playerIndex == .index4)
        #expect(options?.preferredSystemGestureState == options.map { _ in .enabled })
        #expect(home?.preferredSystemGestureState == home.map { _ in .enabled })
    }

    /// A stick or trigger held at Cmd-Tab must release on the PC without removing the pad.
    @Test func focusLossNeutralizesReadyPadWithoutRemovingItsSlot() throws {
        let forwarder = InputForwarder()
        defer { forwarder.detach() }
        let pad = GCController.withExtendedGamepad()
        forwarder.attach(gamepad: pad)
        let slot = try #require(forwarder.attachedControllers[ObjectIdentifier(pad)]?.slot)
        let backend = InputRecordingBackend()
        forwarder.setBackend(backend)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
                              styleMask: .borderless, backing: .buffered, defer: true)
        forwarder.installFocusObservers(for: window)

        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        #expect(backend.calls.isEmpty)

        forwarder.isReady = true
        NotificationCenter.default.post(name: NSWindow.didResignKeyNotification, object: window)
        let sends = backend.calls.filter { $0.num == Int16(slot) }
        #expect(sends.count == 1)
        let sent = try #require(sends.first)
        let analog = sent.analog
        #expect(sent.buttons == 0)
        #expect([analog.leftTrigger, analog.rightTrigger] == [0, 0])
        #expect([analog.leftStickX, analog.leftStickY, analog.rightStickX, analog.rightStickY] == [0, 0, 0, 0])
        #expect(UInt16(bitPattern: sent.mask) & (UInt16(1) << slot) != 0)
    }

    @Test func suspendedDrainKeepsLightsButDropsMotorUpdates() {
        var lights: [UInt8] = []
        var leds: [UInt8] = []
        var rumble: [UInt8] = []
        var triggers: [UInt8] = []
        var hidDispatches = 0
        ControllerHaptics.processDrain(.init(rumble: [0: (10, 20)], submittedAt: [0: 100],
                                             triggers: [0: (30, 40)], lights: [0: (1, 2, 3)],
                                             playerLEDs: [0: 5], gameControllerSlots: [0],
                                             suspended: true, quiesced: false),
                                       actions: .init(light: { slot, _ in lights.append(slot) },
                                                      playerLEDs: { slot, _ in leds.append(slot) },
                                                      hidRumble: { _, _ in hidDispatches += 1 },
                                                      rumble: { slot, _ in rumble.append(slot) },
                                                      triggers: { slot, _ in triggers.append(slot) }))
        #expect(lights == [0])
        #expect(leds == [0])
        #expect(rumble.isEmpty)
        #expect(triggers.isEmpty)
        #expect(hidDispatches == 0)
    }

    @Test func quiescedDrainDiscardsEveryUpdate() {
        var applied = 0
        ControllerHaptics.processDrain(.init(rumble: [0: (10, 20)], submittedAt: [0: 100],
                                             triggers: [0: (30, 40)], lights: [0: (1, 2, 3)],
                                             playerLEDs: [0: 5], gameControllerSlots: [],
                                             suspended: false, quiesced: true),
                                       actions: .init(light: { _, _ in applied += 1 },
                                                      playerLEDs: { _, _ in applied += 1 },
                                                      hidRumble: { _, _ in applied += 1 },
                                                      rumble: { _, _ in applied += 1 },
                                                      triggers: { _, _ in applied += 1 }))
        #expect(applied == 0)
    }

    @Test func drainDispatchesOnlyHIDRumbleAndItsTimestamp() {
        var dispatched: ([UInt8: ControllerHaptics.Rumble], [UInt8: UInt64])?
        var appliedRumble: [UInt8] = []
        let values: [UInt8: ControllerHaptics.Rumble] = [0: (10, 20), 1: (30, 40)]
        let times: [UInt8: UInt64] = [0: 100, 1: 200]
        ControllerHaptics.processDrain(.init(rumble: values, submittedAt: times, triggers: [:],
                                             lights: [:], playerLEDs: [:], gameControllerSlots: [0],
                                             suspended: false, quiesced: false),
                                       actions: .init(light: { _, _ in }, playerLEDs: { _, _ in },
                                                      hidRumble: { dispatched = ($0, $1) },
                                                      rumble: { slot, _ in appliedRumble.append(slot) },
                                                      triggers: { _, _ in }))
        #expect(dispatched?.0.count == 1)
        #expect(dispatched?.0[1]?.low == 30)
        #expect(dispatched?.1 == [1: 200])
        #expect(appliedRumble.sorted() == [0, 1])
    }

    @Test func emptyAndGameControllerOnlyDrainsSkipHIDDispatch() {
        var dispatches = 0
        let actions = ControllerHaptics.DrainActions(light: { _, _ in }, playerLEDs: { _, _ in },
                                                     hidRumble: { _, _ in dispatches += 1 },
                                                     rumble: { _, _ in }, triggers: { _, _ in })
        ControllerHaptics.processDrain(.init(rumble: [:], submittedAt: [:], triggers: [:],
                                             lights: [:], playerLEDs: [:], gameControllerSlots: [],
                                             suspended: false, quiesced: false), actions: actions)
        ControllerHaptics.processDrain(.init(rumble: [0: (1, 2)], submittedAt: [0: 3], triggers: [:],
                                             lights: [:], playerLEDs: [:], gameControllerSlots: [0],
                                             suspended: false, quiesced: false), actions: actions)
        #expect(dispatches == 0)
    }

    /// A pad GameController has no haptics for is not offered rumble.
    @Test func rumbleNeedsHaptics() throws {
        let forwarder = InputForwarder()
        defer { forwarder.detach() }
        let pad = GCController.withExtendedGamepad()
        try #require(pad.haptics == nil)
        forwarder.attach(gamepad: pad)
        let caps = try #require(forwarder.attachedControllers[ObjectIdentifier(pad)]?.arrival.caps)
        #expect(caps & UInt16(StreamProtocol.LI_CCAP_RUMBLE) == 0)
        #expect(caps & UInt16(StreamProtocol.LI_CCAP_TRIGGER_RUMBLE) == 0)
        #expect(caps & UInt16(StreamProtocol.LI_CCAP_ANALOG_TRIGGERS) != 0)
    }

    /// MISC_FLAG is advertised only when a DualSense Mute actually reaches the PC.
    @Test func muteIsAdvertisedOnlyWhenForwarded() {
        let forwarder = InputForwarder()
        defer { forwarder.detach() }
        let pad = GCController.withExtendedGamepad()
        let misc = UInt32(bitPattern: StreamProtocol.MISC_FLAG)
        #expect(forwarder.supportedButtonMask(for: pad, forwardsMute: true) & misc == misc)
        #expect(forwarder.supportedButtonMask(for: pad, forwardsMute: false) & misc == 0)
    }

    /// A slot is stale when its pad left or became a different pad; an unchanged pad
    /// keeps its slot, and a slot never announced has nothing to remove.
    @Test func staleSlotsAreTheGoneAndTheChanged() {
        let xbox = Arrival(type: UInt8(StreamProtocol.LI_CTYPE_XBOX), supportedButtons: 0xFFFF, caps: 0x03)
        let dualSense = Arrival(type: UInt8(StreamProtocol.LI_CTYPE_PS), supportedButtons: 0xFFFF, caps: 0x3F)
        let announced: [UInt8: Arrival] = [0: xbox, 1: dualSense, 2: xbox]
        let current: [UInt8: Arrival] = [0: xbox, 1: xbox, 3: dualSense]
        #expect(InputForwarder.staleControllerSlots(announced: announced, current: current) == [1, 2])
        #expect(InputForwarder.staleControllerSlots(announced: [:], current: current).isEmpty)
        #expect(InputForwarder.staleControllerSlots(announced: current, current: current).isEmpty)
    }

    /// A pad unplugged while the link was down is retired when the stream comes back.
    /// One unplugged mid-stream stays on the ledger until the next stream start, in case
    /// its removal went into a link that had already died.
    @Test func aPadThatLeftIsRetired() throws {
        let forwarder = InputForwarder()
        defer { forwarder.detach() }
        let pad = GCController.withExtendedGamepad()
        forwarder.setReady(true)
        forwarder.attach(gamepad: pad)
        let slot = try #require(forwarder.attachedControllers[ObjectIdentifier(pad)]?.slot)
        #expect(forwarder.announcedControllers[slot] != nil)

        forwarder.setReady(false)
        forwarder.detach(gamepad: pad)
        #expect(forwarder.announcedControllers[slot] != nil)
        forwarder.setReady(true)
        #expect(forwarder.announcedControllers[slot] == nil)

        forwarder.attach(gamepad: pad)
        #expect(forwarder.announcedControllers[slot] != nil)
        forwarder.detach(gamepad: pad)
        #expect(forwarder.announcedControllers[slot] != nil)
        forwarder.setReady(false)
        forwarder.setReady(true)
        #expect(forwarder.announcedControllers[slot] == nil)
    }
}

@MainActor
private final class ControllerFocusTestWindow: NSWindow {
    var focused = false
    override var isKeyWindow: Bool { focused }
}
