// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AppKit
import Carbon.HIToolbox
import Testing
@testable import Glimmer

@MainActor
struct StreamTextRoutingTests {
    @MainActor
    private final class InputSourceState {
        var usesInputMethod = false
        var reads = 0
    }

    private func ready() -> (InputForwarder, InputRecordingBackend, StreamInputView) {
        let forwarder = InputForwarder()
        let backend = InputRecordingBackend()
        forwarder.backend = backend
        forwarder.isReady = true
        forwarder.modifiersNeedResync = false
        let view = StreamInputView()
        view.delegate = forwarder
        view.interpretTextEvent = { _, _ in }
        return (forwarder, backend, view)
    }

    private func key(_ code: Int, mods: NSEvent.ModifierFlags = [], chars: String = "",
                     repeating: Bool = false) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: mods, timestamp: 1,
            windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
            isARepeat: repeating, keyCode: UInt16(code)))
    }

    private func mark(_ view: StreamInputView) {
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
    }

    @Test(arguments: [false, true])
    func unmarkedRepeatsNeverEnterTheTextSystem(captured: Bool) throws {
        let (forwarder, backend, view) = ready()
        forwarder.isMouseCaptured = captured
        var interpretations = 0
        view.interpretTextEvent = { _, _ in interpretations += 1 }
        view.keyDown(with: try key(kVK_ANSI_S, chars: "s", repeating: true))
        #expect(interpretations == 0)
        #expect(backend.keyboard.isEmpty)
        #expect(backend.texts.isEmpty)
    }

    @Test(arguments: [kVK_ANSI_E, kVK_ANSI_U, kVK_ANSI_I, kVK_ANSI_N, kVK_ANSI_Grave], [false, true])
    func capturedDeadKeysAndTheirNextKeyStayPhysical(code: Int, option: Bool) throws {
        let (forwarder, backend, view) = ready()
        forwarder.isMouseCaptured = true
        var interpretations = 0
        view.interpretTextEvent = { view, _ in
            interpretations += 1
            mark(view)
        }
        view.keyDown(with: try key(code, mods: option ? [.option] : []))
        view.keyDown(with: try key(kVK_ANSI_A, chars: "a"))
        #expect(interpretations == 0)
        #expect(!view.hasMarkedText())
        #expect(backend.keyboard.map(\.keyCode) == [
            try #require(vkScanCode(forCarbonKeyCode: code)).wireCode, VKScanCode(vk: 0x41).wireCode
        ])
        #expect(backend.texts.isEmpty)
    }

    @Test func commitKeepsHeldGameInputAndWaitsForModifierReleases() async throws {
        let (forwarder, backend, view) = ready()
        forwarder.heldKeys = [0x57]
        forwarder.heldMouseButtons = [StreamProtocol.BUTTON_LEFT]
        forwarder.heldModifierVKs = [0xA4]
        forwarder.streamView(view, commitText: "é")
        #expect(forwarder.heldKeys == [0x57])
        #expect(forwarder.heldMouseButtons == [StreamProtocol.BUTTON_LEFT])
        #expect(backend.pointer.isEmpty)
        #expect(backend.keyboard.map(\.keyCode) == [VKScanCode(vk: 0xA4).wireCode])
        #expect(backend.texts.isEmpty)
        let pending = try #require(forwarder.pendingTextTask)
        await pending.value
        #expect(backend.texts == ["é"])
    }

    @Test func desktopForwardsCommandWhileKeyWithoutPointerCapture() throws {
        let (forwarder, backend, view) = ready()
        let window = PointerFocusTestWindow()
        forwarder.window = window
        forwarder.captureSysKeys = true
        #expect(forwarder.forwardsCommand)
        #expect(forwarder.streamView(view, handleKeyEquivalent: try key(kVK_ANSI_W, mods: [.command], chars: "w")))
        #expect(backend.keyboard.last?.modifiers == Int8(StreamProtocol.MODIFIER_META))
        window.focused = false
        #expect(!forwarder.forwardsCommand)
    }

    @Test(arguments: [NSEvent.ModifierFlags.control, .command])
    func shortcutCancelsCompositionBeforeAnyGate(mods: NSEvent.ModifierFlags) throws {
        let (forwarder, _, view) = ready()
        forwarder.isReady = false
        mark(view)
        view.keyDown(with: try key(kVK_ANSI_A, mods: mods, chars: "a"))
        #expect(!view.hasMarkedText())
    }

    @Test(arguments: [NSEvent.EventType.leftMouseDown, .rightMouseDown, .otherMouseDown])
    func everyMouseDownCancelsCompositionBeforeTheReadyGate(type: NSEvent.EventType) throws {
        let (forwarder, _, view) = ready()
        forwarder.isReady = false
        mark(view)
        let event = try #require(NSEvent.mouseEvent(
            with: type, location: .zero, modifierFlags: [], timestamp: 1,
            windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        forwarder.streamView(view, handleMouseDown: event)
        #expect(!view.hasMarkedText())
    }

    @Test(arguments: [false, true])
    func escapeHoldWorksDuringReconnectExceptWhileComposing(composing: Bool) throws {
        let (forwarder, _, view) = ready()
        forwarder.isReady = false
        forwarder.isWindowMode = true
        forwarder.isMouseCaptured = true
        defer { forwarder.cancelEscapeHold() }
        if composing { mark(view) }
        view.keyDown(with: try key(kVK_Escape))
        #expect((forwarder.escapeHoldTask != nil) == !composing)
    }

    @Test func inputSourceChangesUpdateCapturedRoutingWithoutPerKeyReads() throws {
        let (forwarder, backend, view) = ready()
        forwarder.isMouseCaptured = true
        let center = NotificationCenter()
        let source = InputSourceState()
        view.observeInputSource(center: center) {
            source.reads += 1
            return source.usesInputMethod
        }
        defer { view.stopObservingInputSource() }
        var interpretations = 0
        view.interpretTextEvent = { view, _ in
            interpretations += 1
            mark(view)
        }
        view.keyDown(with: try key(kVK_ANSI_W, chars: "w"))
        #expect(interpretations == 0)
        #expect(source.reads == 1)
        #expect(backend.keyboard.count == 1)
        source.usesInputMethod = true
        let name = Notification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String)
        center.post(name: name, object: nil)
        view.keyDown(with: try key(kVK_ANSI_N, chars: "n"))
        view.keyDown(with: try key(kVK_ANSI_N, chars: "n", repeating: true))
        #expect(interpretations == 2)
        #expect(source.reads == 2)
        #expect(view.hasMarkedText())
        source.usesInputMethod = false
        center.post(name: name, object: nil)
        #expect(!view.hasMarkedText())
        #expect(!view.usesInputMethod)
        view.keyDown(with: try key(kVK_ANSI_S, chars: "s"))
        #expect(interpretations == 2)
        #expect(source.reads == 3)
        #expect(backend.keyboard.count == 2)
        view.stopObservingInputSource()
        center.post(name: name, object: nil)
        #expect(source.reads == 3)
    }

    @Test func textReleaseDoesNotRepressAPhysicallyHeldModifier() async throws {
        let (forwarder, backend, view) = ready()
        forwarder.heldModifierVKs = [0xA4]
        let task = try #require(forwarder.queueText("é", modifiers: [.option]))
        #expect(forwarder.heldModifierVKs == [0xA4])
        #expect(!forwarder.modifiersNeedResync)
        view.keyDown(with: try key(kVK_ANSI_W, mods: [.option], chars: "w"))
        await task.value
        #expect(backend.keyboard.map(\.keyCode) == [VKScanCode(vk: 0xA4).wireCode, VKScanCode(vk: 0x57).wireCode])
        #expect(backend.keyboard.map(\.action) == [
            Int8(StreamProtocol.KEY_ACTION_UP), Int8(StreamProtocol.KEY_ACTION_DOWN)
        ])
        #expect(backend.texts == ["é"])
    }

    @Test func focusLossDiscardsALiveTextCommit() async throws {
        let (forwarder, backend, view) = ready()
        forwarder.streamView(view, commitText: "你")
        forwarder.windowResignedKey()
        let pending = try #require(forwarder.pendingTextTask)
        await pending.value
        #expect(backend.texts.isEmpty)
    }

    @Test func rapidCommitsStayOrderedAcrossTheReleaseDelay() async throws {
        let (forwarder, backend, _) = ready()
        let texts = (0..<20).map { "字\($0)" }
        for text in texts { forwarder.queueText(text) }
        let last = try #require(forwarder.pendingTextTask)
        await last.value
        #expect(backend.texts == texts)
    }

    @Test func commandEquivalentCancelsCompositionEvenWhenLeftToTheMac() throws {
        let (forwarder, _, view) = ready()
        mark(view)
        #expect(!forwarder.streamView(view, handleKeyEquivalent: try key(kVK_ANSI_A, mods: [.command])))
        #expect(!view.hasMarkedText())
    }

    @Test func systemShortcutCaptureFollowsFocusInEitherPointerMode() {
        let (forwarder, _, _) = ready()
        let window = PointerFocusTestWindow()
        forwarder.window = window
        forwarder.captureSysKeys = true
        var disabled: [Bool] = []
        forwarder.updateSystemKeyCapture { disabled.append($0) }
        forwarder.isMouseCaptured = true
        forwarder.updateSystemKeyCapture { disabled.append($0) }
        window.focused = false
        forwarder.updateSystemKeyCapture { disabled.append($0) }
        window.focused = true
        forwarder.captureSysKeys = false
        forwarder.updateSystemKeyCapture { disabled.append($0) }
        #expect(disabled == [true, true, false, false])
    }
}
