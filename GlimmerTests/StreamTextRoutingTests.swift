// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AppKit
import Carbon.HIToolbox
import Testing
@testable import Glimmer

@MainActor
struct StreamTextRoutingTests {
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
    func failedReleaseKeepsLiveCommitAndFollowingKeysOrdered(paste: Bool) async throws {
        let (forwarder, backend, view) = ready()
        defer { forwarder.detach() }
        view.keyDown(with: try key(kVK_ANSI_W, chars: "w"))
        backend.inputResult = -2
        let up = try #require(NSEvent.keyEvent(
            with: .keyUp, location: .zero, modifierFlags: [], timestamp: 2,
            windowNumber: 0, context: nil, characters: "w", charactersIgnoringModifiers: "w",
            isARepeat: false, keyCode: UInt16(kVK_ANSI_W)))
        view.keyUp(with: up)
        let task = try #require(paste ? forwarder.queuePasteText("你") : forwarder.queueText("你", modifiers: []))
        view.keyDown(with: try key(kVK_ANSI_S, chars: "s"))
        forwarder.queueText("好", modifiers: [])
        try await Task.sleep(for: .milliseconds(80))
        #expect(backend.texts.isEmpty)
        #expect(backend.keyboard.count == 1)
        backend.inputResult = 0
        await task.value
        #expect(backend.orderedKeyboard == [
            .key(VKScanCode(vk: 0x57).wireCode, true), .key(VKScanCode(vk: 0x57).wireCode, false),
            .text("你"), .key(VKScanCode(vk: 0x53).wireCode, true), .text("好")
        ])
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
        forwarder.releases.hold(.key(VKScanCode(vk: 0xA4)))
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
        window.contentView = view
        window.makeFirstResponder(view)
        forwarder.inputView = view
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

    @Test func textReleaseDoesNotRepressAPhysicallyHeldModifier() async throws {
        let (forwarder, backend, view) = ready()
        forwarder.heldModifierVKs = [0xA4]
        forwarder.releases.hold(.key(VKScanCode(vk: 0xA4)))
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
        forwarder.heldModifierVKs = [0xA4]
        forwarder.releases.hold(.key(VKScanCode(vk: 0xA4)))
        forwarder.streamView(view, commitText: "你")
        forwarder.windowResignedKey()
        let pending = try #require(forwarder.pendingTextTask)
        await pending.value
        #expect(backend.texts.isEmpty)
    }

    @Test func rapidCommitsStayOrderedAcrossTheReleaseDelay() async throws {
        let (forwarder, backend, _) = ready()
        forwarder.heldModifierVKs = [0xA4]
        forwarder.releases.hold(.key(VKScanCode(vk: 0xA4)))
        let texts = (0..<20).map { "字\($0)" }
        for text in texts { forwarder.queueText(text, modifiers: []) }
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

    @Test(arguments: [false, true])
    func systemShortcutCaptureFollowsFocusAndPointerMode(windowed: Bool) {
        let (forwarder, _, view) = ready()
        let window = PointerFocusTestWindow()
        window.contentView = view
        window.makeFirstResponder(view)
        forwarder.inputView = view
        forwarder.window = window
        forwarder.captureSysKeys = true
        forwarder.isWindowMode = windowed
        var disabled: [Bool] = []
        forwarder.updateSystemKeyCapture { disabled.append($0) }
        forwarder.isMouseCaptured = true
        forwarder.updateSystemKeyCapture { disabled.append($0) }
        window.focused = false
        forwarder.updateSystemKeyCapture { disabled.append($0) }
        window.focused = true
        forwarder.captureSysKeys = false
        forwarder.updateSystemKeyCapture { disabled.append($0) }
        #expect(disabled == [!windowed, true, false, false])
    }

    @Test func unmodifiedCommitPrecedesTheNextPhysicalKeyImmediately() throws {
        let (forwarder, backend, view) = ready()
        forwarder.queueText("é", modifiers: [])
        #expect(backend.texts == ["é"])
        #expect(forwarder.pendingTextTask == nil)
        view.keyDown(with: try key(kVK_ANSI_S, chars: "s"))
        #expect(backend.orderedKeyboard == [.text("é"), .key(VKScanCode(vk: 0x53).wireCode, true)])
    }

    @Test func modifierWaitHoldsFollowingDownUpAndTextInOrder() async throws {
        let (forwarder, backend, view) = ready()
        forwarder.heldModifierVKs = [0xA4]
        forwarder.releases.hold(.key(VKScanCode(vk: 0xA4)))
        let pending = try #require(forwarder.queueText("你", modifiers: []))
        view.keyDown(with: try key(kVK_Space, chars: " "))
        let up = try #require(NSEvent.keyEvent(
            with: .keyUp, location: .zero, modifierFlags: [], timestamp: 2,
            windowNumber: 0, context: nil, characters: " ", charactersIgnoringModifiers: " ",
            isARepeat: false, keyCode: UInt16(kVK_Space)))
        view.keyUp(with: up)
        forwarder.queueText("好", modifiers: [])
        view.keyDown(with: try key(kVK_Return, chars: "\r"))
        #expect(backend.keyboard.count == 1)
        #expect(backend.texts.isEmpty)
        await pending.value
        #expect(backend.orderedKeyboard == [
            .key(VKScanCode(vk: 0xA4).wireCode, false), .text("你"),
            .key(VKScanCode(vk: 0x20).wireCode, true), .key(VKScanCode(vk: 0x20).wireCode, false),
            .text("好"), .key(VKScanCode(vk: 0x0D).wireCode, true)
        ])
        #expect(forwarder.heldKeys == [0x0D])
        #expect(forwarder.pendingTextTask == nil)
    }

    @Test func queuedModifierAndCommitStartAnotherOrderedWait() async throws {
        let (forwarder, backend, view) = ready()
        forwarder.heldModifierVKs = [0xA4]
        forwarder.releases.hold(.key(VKScanCode(vk: 0xA4)))
        let pending = try #require(forwarder.queueText("é", modifiers: []))
        let shift = try #require(NSEvent.keyEvent(
            with: .flagsChanged, location: .zero, modifierFlags: [.shift], timestamp: 2,
            windowNumber: 0, context: nil, characters: "", charactersIgnoringModifiers: "",
            isARepeat: false, keyCode: UInt16(kVK_Shift)))
        view.flagsChanged(with: shift)
        forwarder.queueText("É", modifiers: [])
        view.keyDown(with: try key(kVK_Return, chars: "\r"))
        #expect(backend.keyboard.count == 1)
        await pending.value
        #expect(backend.orderedKeyboard == [
            .key(VKScanCode(vk: 0xA4).wireCode, false), .text("é"),
            .key(VKScanCode(vk: 0xA0).wireCode, true), .key(VKScanCode(vk: 0xA0).wireCode, false),
            .text("É"), .key(VKScanCode(vk: 0x0D).wireCode, true)
        ])
        #expect(forwarder.pendingTextTask == nil)
    }

    @Test func focusLossDiscardsKeysWaitingBehindText() async throws {
        let (forwarder, backend, view) = ready()
        forwarder.heldModifierVKs = [0xA4]
        forwarder.releases.hold(.key(VKScanCode(vk: 0xA4)))
        let pending = try #require(forwarder.queueText("é", modifiers: []))
        view.keyDown(with: try key(kVK_ANSI_W, chars: "w"))
        forwarder.windowResignedKey()
        await pending.value
        #expect(backend.texts.isEmpty)
        #expect(backend.keyboard.count == 1)
        #expect(forwarder.heldKeys.isEmpty)
    }

    @Test func capturedInputMethodNeverInterpretsMovementKeys() throws {
        let (forwarder, backend, view) = ready()
        forwarder.isMouseCaptured = true
        var interpretations = 0
        view.interpretTextEvent = { view, _ in
            interpretations += 1
            mark(view)
        }
        for code in [kVK_ANSI_W, kVK_ANSI_A, kVK_ANSI_S, kVK_ANSI_D] {
            view.keyDown(with: try key(code))
        }
        #expect(interpretations == 0)
        #expect(backend.keyboard.count == 4)
        #expect(!view.hasMarkedText())
    }

    @Test func capturedPointerRejectsTextCallbacks() {
        let (forwarder, backend, view) = ready()
        forwarder.isMouseCaptured = true
        view.insertText("字", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(backend.texts.isEmpty)
        #expect(forwarder.pendingTextTask == nil)
    }

    @Test(arguments: [false, true], [false, true])
    func commandRoutingHonorsWindowCaptureAndFocus(windowed: Bool, captured: Bool) throws {
        for focused in [false, true] {
            for enabled in [false, true] {
                let (forwarder, backend, view) = ready()
                let window = PointerFocusTestWindow()
                window.focused = focused
                window.contentView = view
                window.makeFirstResponder(view)
                forwarder.inputView = view
                forwarder.window = window
                forwarder.isWindowMode = windowed
                forwarder.isMouseCaptured = captured
                forwarder.captureSysKeys = enabled
                let expected = enabled && focused && (!windowed || captured)
                #expect(forwarder.forwardsCommand == expected)
                let tab = try key(kVK_Tab, mods: [.command])
                #expect(forwarder.streamView(view, handleKeyEquivalent: tab) == expected)
                #expect(backend.keyboard.isEmpty == !expected)
            }
        }
    }

    @Test(arguments: [false, true])
    func shortcutsAndClicksTouchTheInputContextOnlyWhenMarked(marked: Bool) throws {
        let (forwarder, _, view) = ready()
        forwarder.isMouseCaptured = true
        var discards = 0
        view.discardMarkedText = { _ in discards += 1 }
        for mods: NSEvent.ModifierFlags in [.control, .command] {
            if marked { mark(view) }
            view.keyDown(with: try key(kVK_ANSI_A, mods: mods))
            if marked { mark(view) }
            _ = forwarder.streamView(view, handleKeyEquivalent: try key(kVK_ANSI_A, mods: mods))
        }
        for type: NSEvent.EventType in [.leftMouseDown, .rightMouseDown, .otherMouseDown] {
            if marked { mark(view) }
            let event = try #require(NSEvent.mouseEvent(
                with: type, location: .zero, modifierFlags: [], timestamp: 1,
                windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
            forwarder.streamView(view, handleMouseDown: event)
        }
        #expect(discards == (marked ? 7 : 0))
    }
}
