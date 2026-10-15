// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import AppKit
import Carbon.HIToolbox
import GameController
import Testing
@testable import Glimmer

@MainActor
struct InputReleaseTests {
    private func setup() -> (InputForwarder, InputRecordingBackend, StreamInputView) {
        let input = InputForwarder()
        let backend = InputRecordingBackend()
        input.backend = backend
        input.isReady = true
        input.keyboardMonitoringGranted = { true }
        input.physicalKeyState = { _ in true }
        input.currentModifierFlags = { [] }
        input.currentMouseButtons = { 0 }
        return (input, backend, StreamInputView())
    }

    private func key(_ type: NSEvent.EventType, code: Int = kVK_ANSI_W,
                     flags: NSEvent.ModifierFlags = []) throws -> NSEvent {
        try #require(NSEvent.keyEvent(with: type, location: .zero, modifierFlags: flags,
                                     timestamp: 1, windowNumber: 0, context: nil,
                                     characters: "w", charactersIgnoringModifiers: "w",
                                     isARepeat: false, keyCode: UInt16(code)))
    }

    private func focus(_ input: InputForwarder, _ view: StreamInputView) -> InputReleaseWindow {
        let window = InputReleaseWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        window.responder = view
        input.window = window
        input.inputView = view
        return window
    }

    private var down: Int8 { Int8(StreamProtocol.KEY_ACTION_DOWN) }
    private var up: Int8 { Int8(StreamProtocol.KEY_ACTION_UP) }

    private func mouse(_ type: NSEvent.EventType) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 1,
                                       windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 0))
    }

    @Test func backendClosesBeforeForwarderLearnsAndReleaseRetries() throws {
        let (input, backend, view) = setup()
        input.streamView(view, handleKeyDown: try key(.keyDown))
        backend.inputResult = -2
        input.streamView(view, handleKeyUp: try key(.keyUp))
        #expect(backend.keyboard.map(\.action) == [down])
        #expect(input.releases.pending.count == 1)
        backend.inputResult = 0
        input.reconcilePhysicalInputs()
        #expect(backend.keyboard.map(\.action) == [down, up])
        #expect(backend.keyboard[0].keyCode == backend.keyboard[1].keyCode)
    }

    @Test func failedReleaseBarrierPrecedesNewDownAndNeverReplaysOldDown() throws {
        let (input, backend, view) = setup()
        input.streamView(view, handleKeyDown: try key(.keyDown))
        backend.inputResult = -1
        input.streamView(view, handleKeyUp: try key(.keyUp))
        input.streamView(view, handleKeyDown: try key(.keyDown, code: kVK_ANSI_A))
        #expect(backend.keyboard.map(\.action) == [down])
        backend.inputResult = 0
        input.streamView(view, handleKeyDown: try key(.keyDown, code: kVK_ANSI_D))
        #expect(backend.keyboard.map(\.action) == [down, up, down])
        #expect(backend.keyboard.map(\.keyCode) == [VKScanCode(vk: 0x57).wireCode,
                                                  VKScanCode(vk: 0x57).wireCode, VKScanCode(vk: 0x44).wireCode])
    }

    @Test func focusLossDuringReconnectRetainsReleaseOnReplacementConnection() throws {
        let (input, old, view) = setup()
        input.streamView(view, handleKeyDown: try key(.keyDown))
        input.setReady(false)
        input.windowResignedKey()
        input.streamView(view, handleKeyUp: try key(.keyUp))
        let replacement = InputRecordingBackend()
        input.setBackend(replacement)
        input.setReady(true)
        #expect(old.keyboard.map(\.action) == [down])
        #expect(replacement.keyboard.map(\.action) == [up])
        #expect(replacement.keyboard.first?.keyCode == old.keyboard.first?.keyCode)
    }

    @Test func acceptedUpOnCancelledConnectionIsRepeatedAsReleaseOnly() throws {
        let (input, old, view) = setup()
        input.streamView(view, handleKeyDown: try key(.keyDown))
        input.streamView(view, handleKeyUp: try key(.keyUp))
        #expect(old.keyboard.map(\.action) == [down, up])
        input.setReady(false)
        let replacement = InputRecordingBackend()
        input.setBackend(replacement)
        input.setReady(true)
        #expect(replacement.keyboard.map(\.action) == [up])
    }

    @Test func releaseUsesDownTimeIsoMapping() throws {
        let (input, backend, view) = setup()
        input.keyMapping = { vkScanCode(forCarbonKeyCode: $0, isISOKeyboard: true) }
        input.streamView(view, handleKeyDown: try key(.keyDown, code: kVK_ISO_Section))
        input.keyMapping = { vkScanCode(forCarbonKeyCode: $0, isISOKeyboard: false) }
        input.streamView(view, handleKeyUp: try key(.keyUp, code: kVK_ISO_Section))
        #expect(backend.keyboard.map(\.action) == [down, up])
        #expect(backend.keyboard[0].keyCode == backend.keyboard[1].keyCode)
        #expect(backend.keyboard[0].flags == backend.keyboard[1].flags)
    }

    @Test func commandAndModifierChangesCannotForgetAnOfflineRelease() throws {
        let (input, backend, view) = setup()
        let window = focus(input, view)
        defer { withExtendedLifetime(window) {} }
        input.captureSysKeys = true
        input.isMouseCaptured = true
        input.streamView(view, handleFlagsChanged: try key(.flagsChanged, code: kVK_Command, flags: .command))
        input.streamView(view, handleKeyDown: try key(.keyDown, flags: .command))
        backend.inputResult = -2
        input.releaseCommandSides()
        input.streamView(view, handleKeyUp: try key(.keyUp, flags: .command))
        #expect(input.releases.pending.count == 2)
        backend.inputResult = 0
        input.flushPendingReleases()
        #expect(backend.keyboard.map(\.action) == [down, down, up, up])
        #expect(backend.keyboard.prefix(2).map(\.keyCode) == backend.keyboard.suffix(2).map(\.keyCode))
    }

    @Test(arguments: [false, true])
    func missingUpIsRepairedByPeriodicCheckOrMainThreadGap(gap: Bool) throws {
        let (input, backend, view) = setup()
        let window = focus(input, view)
        defer { withExtendedLifetime(window) {} }
        input.streamView(view, handleKeyDown: try key(.keyDown))
        input.physicalKeyState = { _ in false }
        input.reconcilePhysicalInputs()
        #expect(backend.keyboard.map(\.action) == [down])
        if gap {
            input.lastInputEventTime = 1
            input.noteInputEvent(now: 1.101)
        } else {
            input.reconciliationTimer?.fire()
        }
        #expect(backend.keyboard.map(\.action) == [down, up])
        #expect(input.reconciliationTimer == nil)
        input.reconcilePhysicalInputs()
        #expect(backend.keyboard.count == 2)
    }

    @Test func physicalModifierFlagsRepairMissingUp() throws {
        let (input, backend, view) = setup()
        let window = focus(input, view)
        defer { withExtendedLifetime(window) {} }
        input.streamView(view, handleFlagsChanged: try key(.flagsChanged, code: kVK_Shift, flags: .shift))
        input.reconcilePhysicalInputs()
        input.reconcilePhysicalInputs()
        #expect(backend.keyboard.map(\.action) == [down, up])
        #expect(backend.keyboard.first?.keyCode == backend.keyboard.last?.keyCode)
    }

    @Test func mouseUpOutsideCaptureRetainsFailedRelease() throws {
        let (input, backend, view) = setup()
        let window = InputReleaseWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        input.window = window
        defer { withExtendedLifetime(window) {} }
        input.isMouseCaptured = true
        input.streamView(view, handleMouseDown: try mouse(.leftMouseDown))
        input.isMouseCaptured = false
        backend.inputResult = -2
        input.streamView(view, handleMouseUp: try mouse(.leftMouseUp))
        backend.inputResult = 0
        input.flushPendingReleases()
        #expect(backend.pointer == [.button(action: Int8(StreamProtocol.BUTTON_ACTION_PRESS), button: 1),
                                    .button(action: Int8(StreamProtocol.BUTTON_ACTION_RELEASE), button: 1)])
    }

    @Test func missingMouseUpIsReconciledFromOsButtons() throws {
        let (input, backend, view) = setup()
        let window = InputReleaseWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        input.window = window
        defer { withExtendedLifetime(window) {} }
        input.isMouseCaptured = true
        input.streamView(view, handleMouseDown: try mouse(.leftMouseDown))
        input.reconcilePhysicalInputs()
        #expect(backend.pointer.last == .button(action: Int8(StreamProtocol.BUTTON_ACTION_RELEASE), button: 1))
        #expect(backend.pointer.count == 2)
    }

    @Test func controllerFailureAndReconnectDiscardOldNeutralFrames() {
        let (input, backend, _) = setup()
        input.gamepadMask = 1
        input.sendControllerState(slot: 0, buttons: StreamProtocol.A_FLAG,
                                  analog: InputForwarder.neutralControllerAnalog)
        backend.inputResult = -2
        input.sendControllerState(slot: 0, buttons: 0, analog: InputForwarder.neutralControllerAnalog)
        input.setReady(false)
        input.windowResignedKey()
        let replacement = InputRecordingBackend()
        input.setBackend(replacement)
        input.setReady(true)
        input.sendControllerState(slot: 0, buttons: StreamProtocol.B_FLAG,
                                  analog: InputForwarder.neutralControllerAnalog)
        #expect(backend.calls.map(\.buttons) == [StreamProtocol.A_FLAG])
        #expect(replacement.calls.map(\.buttons) == [StreamProtocol.B_FLAG])
    }

    @Test func quitChordDoesNotWithholdUnrelatedRelease() {
        let (input, backend, _) = setup()
        input.controllerQuitChordProvider = { .l1r1 }
        input.gamepadMask = 1
        let analog = InputForwarder.neutralControllerAnalog
        input.pushHID(slot: 0, state: (StreamProtocol.A_FLAG, analog), readState: { nil })
        input.pushHID(slot: 0, state: (StreamProtocol.LB_FLAG | StreamProtocol.RB_FLAG, analog), readState: { nil })
        defer { input.cancelQuitChordDwell() }
        #expect(backend.calls.map(\.buttons) == [StreamProtocol.A_FLAG, 0])
    }

    @Test(arguments: [NSWorkspace.willSleepNotification, NSWorkspace.screensDidSleepNotification,
                      NSApplication.didResignActiveNotification])
    func sleepAndDeactivationReleaseAll(name: Notification.Name) throws {
        let (input, backend, view) = setup()
        input.installInputRecoveryObservers()
        defer { input.removeInputRecoveryObservers() }
        input.streamView(view, handleKeyDown: try key(.keyDown))
        let center = name == NSApplication.didResignActiveNotification
            ? NotificationCenter.default : NSWorkspace.shared.notificationCenter
        center.post(name: name, object: nil)
        #expect(backend.keyboard.map(\.action) == [down, up])
    }

    @Test func firstResponderLossAndOfflineTeardownKeepReleaseObligation() throws {
        let input = InputForwarder()
        let backend = InputRecordingBackend()
        let window = NSWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        input.attach(to: window)
        input.backend = backend
        input.isReady = true
        input.window = nil
        let view = try #require(input.inputView)
        input.streamView(view, handleKeyDown: try key(.keyDown))
        backend.inputResult = -2
        _ = view.resignFirstResponder()
        input.detach()
        backend.inputResult = 0
        input.setReady(true)
        #expect(backend.keyboard.map(\.action) == [down, up])
    }
    @Test(arguments: [NSWorkspace.didWakeNotification, NSWorkspace.screensDidWakeNotification,
                      NSApplication.didBecomeActiveNotification])
    func wakeAndReactivationReconcileBeforeAnotherEvent(name: Notification.Name) throws {
        let (input, backend, view) = setup()
        let window = focus(input, view)
        defer { withExtendedLifetime(window) {} }
        input.installInputRecoveryObservers()
        defer { input.removeInputRecoveryObservers() }
        input.streamView(view, handleKeyDown: try key(.keyDown))
        input.physicalKeyState = { _ in false }
        let center = name == NSApplication.didBecomeActiveNotification
            ? NotificationCenter.default : NSWorkspace.shared.notificationCenter
        center.post(name: name, object: nil)
        input.reconcilePhysicalInputs()
        #expect(backend.keyboard.map(\.action) == [down, up])
    }

    @Test func refocusRepairsMissingReleaseAndUnfocusedDownsStayLocal() throws {
        let (input, backend, view) = setup()
        let window = InputReleaseWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        input.window = window
        input.inputView = view
        window.responder = view
        input.installFocusObservers(for: window)
        defer { input.removeFocusObservers() }
        input.streamView(view, handleKeyDown: try key(.keyDown))
        input.physicalKeyState = { _ in false }
        NotificationCenter.default.post(name: NSWindow.didBecomeKeyNotification, object: window)
        input.reconcilePhysicalInputs()
        #expect(backend.keyboard.map(\.action) == [down, up])
        window.responder = nil
        input.streamView(view, handleKeyDown: try key(.keyDown, code: kVK_ANSI_A))
        #expect(backend.keyboard.count == 2)
    }

    @Test func idleReconciliationNeverQueriesTheOs() {
        let (input, backend, _) = setup()
        var queries = 0
        input.physicalKeyState = { _ in queries += 1; return false }
        input.currentModifierFlags = { queries += 1; return [] }
        input.currentMouseButtons = { queries += 1; return 0 }
        input.lastInputEventTime = 1
        input.noteInputEvent(now: 2)
        input.reconcilePhysicalInputs()
        #expect(queries == 0)
        #expect(input.reconciliationTimer == nil)
        #expect(backend.keyboard.isEmpty)
    }

    @Test func releaseBarrierRetriesOnReadyBeforeControllerAnnouncements() throws {
        let (input, backend, view) = setup()
        input.streamView(view, handleKeyDown: try key(.keyDown))
        input.setReady(false)
        backend.inputResult = -2
        input.setReady(true)
        #expect(input.controllersNeedAnnouncement)
        backend.inputResult = 0
        input.reconcilePhysicalInputs()
        #expect(backend.keyboard.map(\.action) == [down, up])
        #expect(!input.controllersNeedAnnouncement)
    }
    @Test func mouseReleaseSurvivesFocusLossAndConnectionReplacement() throws {
        let (input, old, view) = setup()
        let window = InputReleaseWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)
        input.window = window
        defer { withExtendedLifetime(window) {} }
        input.isMouseCaptured = true
        input.streamView(view, handleMouseDown: try mouse(.leftMouseDown))
        input.setReady(false)
        input.raiseAllHeldInputs(reason: "focus loss")
        input.streamView(view, handleMouseUp: try mouse(.leftMouseUp))
        let replacement = InputRecordingBackend()
        input.setBackend(replacement)
        input.setReady(true)
        #expect(old.pointer == [.button(action: Int8(StreamProtocol.BUTTON_ACTION_PRESS), button: 1)])
        #expect(replacement.pointer == [.button(action: Int8(StreamProtocol.BUTTON_ACTION_RELEASE), button: 1)])
    }

    @Test func periodicControllerCheckRepairsMissingButtonAndTriggerUps() throws {
        let (input, backend, _) = setup()
        let controller = GCController.withExtendedGamepad()
        input.attach(gamepad: controller)
        defer { input.detach() }
        let pad = try #require(controller.extendedGamepad)
        let slot = try #require(input.attachedControllers[ObjectIdentifier(controller)]?.slot)
        pad.valueChangedHandler = nil
        let baseline = backend.calls.count
        pad.buttonA.setValue(1)
        pad.leftTrigger.setValue(1)
        input.sendGamepadUpdate(pad: pad, slot: slot)
        pad.buttonA.setValue(0)
        pad.leftTrigger.setValue(0)
        input.reconciliationTimer?.fire()
        let sends = backend.calls.dropFirst(baseline)
        #expect(sends.map(\.buttons) == [StreamProtocol.A_FLAG, 0])
        #expect(sends.map(\.analog.leftTrigger) == [255, 0])
    }

    @Test func quitChordAllowsTriggerReleaseWithoutSendingChordButtons() {
        let (input, backend, _) = setup()
        input.gamepadMask = 1
        input.controllerQuitChordProvider = { .l1r1 }
        var analog = InputForwarder.neutralControllerAnalog
        analog.leftTrigger = 255
        input.pushHID(slot: 0, state: (0, analog), readState: { nil })
        let chord = StreamProtocol.LB_FLAG | StreamProtocol.RB_FLAG
        input.pushHID(slot: 0, state: (chord, InputForwarder.neutralControllerAnalog), readState: { nil })
        defer { input.cancelQuitChordDwell() }
        #expect(backend.calls.map(\.buttons) == [0, 0])
        #expect(backend.calls.map(\.analog.leftTrigger) == [255, 0])
    }

    @Test func pendingControllerRemovalClearsSlotBeforeItCanBeReused() {
        let (input, backend, _) = setup()
        input.gamepadMask = 1
        input.sendControllerState(slot: 0, buttons: StreamProtocol.A_FLAG,
                                  analog: InputForwarder.neutralControllerAnalog)
        backend.inputResult = -2
        input.sendControllerRemoval(slot: 0)
        backend.inputResult = 0
        input.sendControllerState(slot: 0, buttons: StreamProtocol.B_FLAG,
                                  analog: InputForwarder.neutralControllerAnalog)
        #expect(backend.calls.map(\.mask) == [1, 0, 1])
        #expect(backend.calls.map(\.buttons) == [StreamProtocol.A_FLAG, 0, StreamProtocol.B_FLAG])
    }

    @Test func sessionStopHandsControllerNeutralToChannelBeforeClosingBackend() async {
        let (input, backend, _) = setup()
        input.gamepadMask = 1
        input.sendControllerState(slot: 0, buttons: StreamProtocol.A_FLAG,
                                  analog: InputForwarder.neutralControllerAnalog)
        let session = StreamSession(hostDisposition: .cancelOwnedHostSession, backend: backend)
        await session.adoptInputForReleaseTest(input)
        await session.stop()
        #expect(backend.controllersAtStop.map(\.buttons) == [StreamProtocol.A_FLAG, 0])
    }

    @Test func controllerReleaseBehindFailedKeyboardBarrierCannotDisappear() throws {
        let (input, backend, view) = setup()
        input.streamView(view, handleKeyDown: try key(.keyDown))
        input.sendControllerState(slot: 0, buttons: StreamProtocol.A_FLAG,
                                  analog: InputForwarder.neutralControllerAnalog)
        backend.inputResult = -2
        input.streamView(view, handleKeyUp: try key(.keyUp))
        input.sendControllerState(slot: 0, buttons: 0, analog: InputForwarder.neutralControllerAnalog)
        backend.inputResult = 0
        input.flushPendingReleases()
        #expect(backend.keyboard.map(\.action) == [down, up])
        #expect(backend.calls.map(\.buttons) == [StreamProtocol.A_FLAG, 0])
    }
}

@MainActor
private final class InputReleaseWindow: NSWindow {
    weak var responder: NSResponder?
    override var firstResponder: NSResponder? { responder }
    override var isKeyWindow: Bool { true }
}

private extension StreamSession {
    func adoptInputForReleaseTest(_ input: InputForwarder) async {
        isStreaming = true
        self.input = await SessionInputHooks(input)
    }
}
