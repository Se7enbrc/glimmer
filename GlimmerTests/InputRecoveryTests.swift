// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AppKit
import Carbon.HIToolbox
import GameController
import Testing
@testable import Glimmer

@MainActor
struct InputRecoveryTests {
    @MainActor private struct Rig {
        let input = InputForwarder()
        let backend = InputRecordingBackend()
        let view = StreamInputView()
        let window = RecoveryWindow(contentRect: .zero, styleMask: .borderless, backing: .buffered, defer: true)

        init() {
            input.backend = backend
            input.isReady = true
            input.window = window
            input.inputView = view
            window.responder = view
            input.keyboardMonitoringGranted = { true }
            input.physicalKeyState = { _ in false }
            input.currentModifierFlags = { [] }
            input.currentMouseButtons = { 0 }
        }

        func key(_ type: NSEvent.EventType, code: Int = kVK_ANSI_W,
                 flags: NSEvent.ModifierFlags = [], repeatKey: Bool = false) throws {
            let event = try #require(NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags, timestamp: 1, windowNumber: 0,
                context: nil, characters: "w", charactersIgnoringModifiers: "w",
                isARepeat: repeatKey, keyCode: UInt16(code)))
            switch type {
            case .keyDown: input.streamView(view, handleKeyDown: event)
            case .keyUp: input.streamView(view, handleKeyUp: event)
            default: input.streamView(view, handleFlagsChanged: event)
            }
        }
    }

    @Test func reconciliationRetiresAfterControllerReleaseAndIgnoresIdleMouseMode() {
        let rig = Rig()
        defer { rig.input.detach() }
        let controller = GCController.withExtendedGamepad()
        defer { withExtendedLifetime(controller) {} }
        rig.input.attach(gamepad: controller)
        rig.input.sendControllerState(slot: 0, buttons: StreamProtocol.A_FLAG,
                                      analog: InputForwarder.neutralControllerAnalog)
        rig.input.updateReconciliationTimer()
        #expect(rig.input.reconciliationTimer != nil)
        rig.input.tickReconciliation()
        #expect(rig.backend.calls.last?.buttons == 0)
        #expect(rig.input.reconciliationTimer == nil)
        rig.input.controllerMouseStates[0] = ControllerMouseState(isMouse: true)
        rig.input.updateReconciliationTimer()
        #expect(rig.input.reconciliationTimer == nil)
    }

    @Test func deniedMonitoringNeverReleasesHeldKeys() throws {
        let rig = Rig()
        defer { rig.input.detach() }
        rig.input.keyboardMonitoringGranted = { false }
        try rig.key(.keyDown)
        for _ in 0..<3 { rig.input.reconcilePhysicalInputs() }
        #expect(rig.backend.keyboard.count == 1)
        #expect(rig.input.physicalKeys.count == 1)
    }

    @Test func missingKeyNeedsTwoSamplesAndAnInterveningEventRestartsThem() throws {
        let rig = Rig()
        defer { rig.input.detach() }
        try rig.key(.keyDown)
        rig.input.reconcilePhysicalInputs()
        #expect(rig.backend.keyboard.count == 1)
        try rig.key(.keyDown, repeatKey: true)
        rig.input.reconcilePhysicalInputs()
        #expect(rig.backend.keyboard.count == 1)
        rig.input.reconcilePhysicalInputs()
        #expect(rig.backend.keyboard.map(\.action) == [3, 4])
    }

    @Test func aHeldSampleOrPermissionLossRestartsConfirmation() throws {
        let rig = Rig()
        defer { rig.input.detach() }
        try rig.key(.keyDown)
        rig.input.reconcilePhysicalInputs()
        rig.input.physicalKeyState = { _ in true }
        rig.input.reconcilePhysicalInputs()
        rig.input.physicalKeyState = { _ in false }
        rig.input.reconcilePhysicalInputs()
        #expect(rig.backend.keyboard.count == 1)
        rig.input.keyboardMonitoringGranted = { false }
        rig.input.reconcilePhysicalInputs()
        rig.input.keyboardMonitoringGranted = { true }
        rig.input.reconcilePhysicalInputs()
        #expect(rig.backend.keyboard.count == 1)
        rig.input.reconcilePhysicalInputs()
        #expect(rig.backend.keyboard.map(\.action) == [3, 4])
    }

    @Test(arguments: [false, true])
    func unfocusedKeyboardNeverQueriesPhysicalState(otherResponder: Bool) throws {
        let rig = Rig()
        defer { rig.input.detach() }
        try rig.key(.keyDown)
        if otherResponder { rig.window.responder = nil } else { rig.window.focused = false }
        var queries = 0
        rig.input.physicalKeyState = { _ in queries += 1; return false }
        for _ in 0..<3 { rig.input.reconcilePhysicalInputs() }
        #expect(queries == 0)
        #expect(rig.backend.keyboard.count == 1)
    }

    @Test(arguments: [false, true])
    func miniPlayerKeepsControllerAndQuitDwellOnOwnershipLoss(responder: Bool) throws {
        let rig = Rig()
        defer { rig.input.detach() }
        rig.input.attach(to: rig.window)
        rig.input.isMiniPlayer = true
        rig.input.gamepadMask = 1
        rig.input.sendControllerState(slot: 0, buttons: StreamProtocol.A_FLAG,
                                      analog: InputForwarder.neutralControllerAnalog)
        rig.input.quitChordDwellTask = Task { try? await Task.sleep(for: .seconds(10)) }
        if responder {
            _ = rig.input.inputView?.resignFirstResponder()
        } else {
            NotificationCenter.default.post(name: NSApplication.didResignActiveNotification, object: nil)
        }
        #expect(rig.backend.calls.map(\.buttons) == [StreamProtocol.A_FLAG])
        #expect(rig.input.quitChordDwellTask != nil)
    }

    @Test func reconnectAnnouncesBeforeControllerState() {
        let rig = Rig()
        defer { rig.input.detach() }
        rig.input.attach(gamepad: GCController.withExtendedGamepad())
        rig.input.sendControllerState(slot: 0, buttons: StreamProtocol.A_FLAG,
                                      analog: InputForwarder.neutralControllerAnalog)
        rig.input.setReady(false)
        #expect(rig.input.reconciliationTimer == nil)
        let replacement = InputRecordingBackend()
        rig.input.setBackend(replacement)
        rig.input.setReady(true)
        #expect(replacement.controllerEvents.first == "arrival")
    }

    @Test func failedBarrierDoesNotPretendNewModifierWasSent() throws {
        let rig = Rig()
        defer { rig.input.detach() }
        try rig.key(.flagsChanged, code: kVK_Shift, flags: .shift)
        rig.backend.inputResult = -2
        try rig.key(.flagsChanged, code: kVK_Control, flags: .control)
        #expect(!rig.input.heldModifierVKs.contains(0xA2))
        #expect(rig.input.modifiersNeedResync)
        rig.backend.inputResult = 0
        try rig.key(.keyDown, flags: .control)
        #expect(rig.backend.keyboard.map(\.keyCode) == [0xA0, 0xA0, 0xA2, 0x57].map {
            VKScanCode(vk: $0).wireCode
        })
    }

    @Test(arguments: [2, 3, 4, 5, 6])
    func mouseReconciliationUsesOriginalButton(number: Int) throws {
        let rig = Rig()
        defer { rig.input.detach() }
        rig.input.isMouseCaptured = true
        let down = try #require(CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown,
                                        mouseCursorPosition: .zero, mouseButton: .center))
        down.setIntegerValueField(.mouseEventButtonNumber, value: Int64(number))
        rig.input.streamView(rig.view, handleMouseDown: try #require(NSEvent(cgEvent: down)))
        rig.input.reconcilePhysicalInputs()
        #expect(rig.backend.pointer.count == (number < 5 ? 2 : 1))
        let up = try #require(CGEvent(mouseEventSource: nil, mouseType: .otherMouseUp,
                                      mouseCursorPosition: .zero, mouseButton: .center))
        up.setIntegerValueField(.mouseEventButtonNumber, value: Int64(number))
        rig.input.streamView(rig.view, handleMouseUp: try #require(NSEvent(cgEvent: up)))
        #expect(rig.backend.pointer.count == 2)
    }

    @Test func replacementDoesNotRememberReleasesFromEveryEarlierConnection() throws {
        let rig = Rig()
        defer { rig.input.detach() }
        try rig.key(.keyDown)
        try rig.key(.keyUp)
        rig.input.setReady(false)
        let second = InputRecordingBackend()
        rig.input.setBackend(second)
        rig.input.setReady(true)
        #expect(second.keyboard.count == 1)
        rig.input.setReady(false)
        let third = InputRecordingBackend()
        rig.input.setBackend(third)
        rig.input.setReady(true)
        #expect(third.keyboard.isEmpty)
    }

    @Test func pasteWaitsForTheFailedShiftRelease() async throws {
        let rig = Rig()
        defer { rig.input.detach() }
        try rig.key(.flagsChanged, code: kVK_Shift, flags: .shift)
        rig.backend.inputResult = -2
        let paste = try #require(rig.input.queuePasteText("text"))
        try await Task.sleep(for: .milliseconds(100))
        #expect(rig.backend.texts.isEmpty)
        rig.backend.inputResult = 0
        await paste.value
        #expect(rig.input.releases.pending.isEmpty)
        #expect(rig.backend.keyboard.map(\.action) == [3, 4])
        #expect(rig.backend.texts == ["text"])
    }
}

@MainActor
private final class RecoveryWindow: NSWindow {
    var focused = true
    weak var responder: NSResponder?
    override var isKeyWindow: Bool { focused }
    override var firstResponder: NSResponder? { responder }
}
