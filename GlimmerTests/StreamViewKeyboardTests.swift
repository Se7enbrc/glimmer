// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Client chords, Caps Lock and modifier bytes on the way to the backend.

import GlimmerEngine
import AppKit
import Carbon.HIToolbox
import Testing
@testable import Glimmer

@MainActor
struct StreamViewKeyboardTests {
    @MainActor
    private final class Tally { var calls = 0 }

    private let down = Int8(StreamProtocol.KEY_ACTION_DOWN)
    private let up = Int8(StreamProtocol.KEY_ACTION_UP)
    private func wire(_ vk: Int16) -> Int16 { VKScanCode(vk: vk).wireCode }

    private func key(_ type: NSEvent.EventType, _ keyCode: Int, mods: NSEvent.ModifierFlags = [],
                     chars: String = "", isRepeat: Bool = false, at timestamp: TimeInterval = 1) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: mods, timestamp: timestamp,
            windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
            isARepeat: isRepeat, keyCode: UInt16(keyCode)))
    }

    private func ready() -> (InputForwarder, InputRecordingBackend, StreamInputView) {
        let forwarder = InputForwarder()
        let backend = InputRecordingBackend()
        forwarder.setBackend(backend)
        forwarder.isReady = true
        let view = StreamInputView()
        view.delegate = forwarder
        view.interpretTextEvent = { view, event in
            view.insertText(event.characters ?? "", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        return (forwarder, backend, view)
    }

    @Test func directLayoutCharactersKeepTheirPhysicalKeys() throws {
        let (forwarder, backend, view) = ready()
        forwarder.modifiersNeedResync = false
        for text in ["a", "q", "ж", "あ"] {
            view.keyDown(with: try key(.keyDown, kVK_ANSI_A, chars: text))
            view.keyUp(with: try key(.keyUp, kVK_ANSI_A, chars: text, at: Double(backend.keyboard.count + 2)))
        }
        #expect(backend.texts.isEmpty)
        #expect(backend.keyboard.map(\.keyCode) == Array(repeating: wire(0x41), count: 8))
    }

    @Test func unmappedPrintableInputUsesTextWhileEmptyInputFallsBack() async throws {
        let (forwarder, backend, view) = ready()
        view.keyDown(with: try key(.keyDown, 255, chars: "字"))
        view.keyUp(with: try key(.keyUp, 255, chars: "字", at: 2))
        await forwarder.pendingTextTask?.value
        #expect(backend.texts == ["字"])
        #expect(backend.keyboard.isEmpty)
        view.keyDown(with: try key(.keyDown, kVK_Function))
        #expect(forwarder.loggedUnmappedKeyCodes == [UInt16(kVK_Function)])
    }

    @Test func textDecisionDistinguishesCompositionAndUnmappedInput() throws {
        let event = try key(.keyDown, kVK_ANSI_E, chars: "e")
        #expect(StreamTextInput.usesPhysicalKey(text: "e", event: event, composing: false))
        #expect(!StreamTextInput.usesPhysicalKey(text: "e", event: event, composing: true))
        #expect(!StreamTextInput.usesPhysicalKey(text: "é", event: event, composing: false))
        #expect(!StreamTextInput.usesPhysicalKey(text: "字", event: nil, composing: false))
        let unmapped = try key(.keyDown, 255, chars: "字")
        #expect(!StreamTextInput.usesPhysicalKey(text: "字", event: unmapped, composing: false))
    }

    @Test func markedInputStaysLocalUntilOneCommit() async throws {
        let (forwarder, backend, view) = ready()
        forwarder.modifiersNeedResync = false
        view.interpretTextEvent = { view, _ in
            view.setMarkedText(NSAttributedString(string: "ni"), selectedRange: NSRange(location: 2, length: 0),
                               replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        view.keyDown(with: try key(.keyDown, kVK_ANSI_N, chars: "n"))
        view.keyUp(with: try key(.keyUp, kVK_ANSI_N, chars: "n", at: 2))
        #expect(view.hasMarkedText())
        #expect(view.markedRange() == NSRange(location: 0, length: 2))
        #expect(backend.keyboard.isEmpty)
        #expect(backend.texts.isEmpty)
        view.interpretTextEvent = { view, _ in
            view.insertText(NSAttributedString(string: "你"), replacementRange: NSRange(location: 0, length: 2))
        }
        view.keyDown(with: try key(.keyDown, kVK_Return, chars: "\r", at: 3))
        view.keyUp(with: try key(.keyUp, kVK_Return, chars: "\r", at: 4))
        #expect(!view.hasMarkedText())
        await forwarder.pendingTextTask?.value
        #expect(backend.texts == ["你"])
        #expect(backend.keyboard.isEmpty)
    }

    @Test func deadKeyCompositionAndCharacterViewerSendOnlyText() async throws {
        let (forwarder, backend, view) = ready()
        defer { forwarder.isReady = false }
        view.setMarkedText("´", selectedRange: NSRange(location: 1, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        view.interpretTextEvent = { view, _ in
            view.insertText("é", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        view.keyDown(with: try key(.keyDown, kVK_ANSI_E, chars: "é"))
        view.insertText("\u{1F642}", replacementRange: NSRange(location: NSNotFound, length: 0))
        await forwarder.pendingTextTask?.value
        #expect(backend.texts == ["é", "\u{1F642}"])
        #expect(backend.keyboard.isEmpty)
    }

    @Test func shortcutsBypassTextInterpretation() throws {
        let (forwarder, backend, view) = ready()
        forwarder.modifiersNeedResync = false
        let calls = Tally()
        view.interpretTextEvent = { _, _ in calls.calls += 1 }
        view.keyDown(with: try key(.keyDown, kVK_ANSI_A, mods: [.control], chars: "a"))
        #expect(calls.calls == 0)
        #expect(backend.keyboard.last?.keyCode == wire(0x41))
    }

    @Test func escapeCancelsCompositionWithoutArmingThePointerHold() throws {
        let (forwarder, backend, view) = ready()
        forwarder.isWindowMode = true
        view.setMarkedText("ni", selectedRange: NSRange(location: 2, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        view.interpretTextEvent = { view, _ in view.doCommand(by: #selector(NSResponder.cancelOperation(_:))) }
        view.keyDown(with: try key(.keyDown, kVK_Escape, chars: "\u{1b}"))
        #expect(!view.hasMarkedText())
        #expect(forwarder.escapeHoldTask == nil)
        #expect(backend.keyboard.isEmpty)
        #expect(backend.texts.isEmpty)
    }

    @Test func compositionCancellationAndClosedGateNeverCommit() {
        let (forwarder, backend, view) = ready()
        forwarder.inputView = view
        view.setMarkedText("かな", selectedRange: NSRange(location: 2, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        forwarder.windowResignedKey()
        #expect(!view.hasMarkedText())
        #expect(backend.texts.isEmpty)
        forwarder.isReady = false
        view.insertText("字", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(backend.texts.isEmpty)
    }

    @Test func unmarkCommitsOnlyOnceAndRangesUseUTF16() async throws {
        let (forwarder, backend, view) = ready()
        defer { forwarder.isReady = false }
        view.setMarkedText("\u{1F642}", selectedRange: NSRange(location: 2, length: 0),
                           replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(view.markedRange().length == 2)
        #expect(view.selectedRange().location == 2)
        var actual = NSRange()
        #expect(view.attributedSubstring(forProposedRange: NSRange(location: 0, length: 100),
                                         actualRange: &actual)?.string == "\u{1F642}")
        #expect(actual == NSRange(location: 0, length: 2))
        view.unmarkText()
        view.unmarkText()
        await forwarder.pendingTextTask?.value
        #expect(backend.texts == ["\u{1F642}"])
    }

    @Test func aKeyGoesOutWithItsModifiersAfterTheModifierItself() throws {
        let (forwarder, backend, view) = ready()
        view.keyDown(with: try key(.keyDown, kVK_ANSI_A, mods: [.shift, .option], chars: "a"))
        view.keyUp(with: try key(.keyUp, kVK_ANSI_A, mods: [.shift, .option], chars: "a", at: 2))
        let mods = Int8(StreamProtocol.MODIFIER_SHIFT | StreamProtocol.MODIFIER_ALT)
        #expect(backend.keyboard == [
            .init(keyCode: wire(0xA0), action: down, modifiers: mods, flags: 0),
            .init(keyCode: wire(0xA4), action: down, modifiers: mods, flags: 0),
            .init(keyCode: wire(0x41), action: down, modifiers: mods, flags: 0),
            .init(keyCode: wire(0x41), action: up, modifiers: mods, flags: 0)
        ])
        #expect(forwarder.heldKeys.isEmpty)
    }

    @Test func repeatsAndAClosedGateSendNothing() throws {
        let (forwarder, backend, view) = ready()
        forwarder.modifiersNeedResync = false
        view.keyDown(with: try key(.keyDown, kVK_ANSI_W, chars: "w", isRepeat: true))
        forwarder.isReady = false
        view.keyDown(with: try key(.keyDown, kVK_ANSI_W, chars: "w"))
        view.flagsChanged(with: try key(.flagsChanged, kVK_Shift, mods: [.shift]))
        view.keyUp(with: try key(.keyUp, kVK_ANSI_W, chars: "w"))
        #expect(backend.keyboard.isEmpty)
        #expect(forwarder.heldKeys.isEmpty)
    }

    @Test func modifierByteFoldsCommandOnlyWhileItIsForwarded() {
        let forwarder = InputForwarder()
        #expect(forwarder.modifierByte(from: [.control, .shift, .option, .command]) == 0x07)
        let window = PointerFocusTestWindow()
        forwarder.window = window
        forwarder.captureSysKeys = true
        #expect(forwarder.modifierByte(from: [.control, .shift, .option, .command]) == 0x0F)
        #expect(forwarder.modifierByte(from: [.capsLock, .function]) == 0)
    }

    /// Windows toggles on each press, so one Mac toggle is a full press and release.
    @Test func capsLockToggleIsOneTapEachWay() throws {
        let (forwarder, backend, view) = ready()
        forwarder.modifiersNeedResync = false
        view.flagsChanged(with: try key(.flagsChanged, kVK_CapsLock, mods: [.capsLock]))
        view.flagsChanged(with: try key(.flagsChanged, kVK_CapsLock))
        #expect(backend.keyboard.map(\.keyCode) == Array(repeating: wire(0x14), count: 4))
        #expect(backend.keyboard.map(\.action) == [down, up, down, up])
        #expect(forwarder.heldKeys.isEmpty)
    }

    @Test func shiftWhileCapsLockIsOnSendsOnlyShift() throws {
        let (forwarder, backend, view) = ready()
        forwarder.lastCapsLock = true
        view.flagsChanged(with: try key(.flagsChanged, kVK_Shift, mods: [.capsLock, .shift]))
        #expect(backend.keyboard.map(\.keyCode) == [wire(0xA0)])
        #expect(forwarder.heldModifierVKs == [0xA0])
    }

    // MARK: Client chords are consumed, never forwarded

    @Test(arguments: [false, true], [false, true])
    func persistedControlZTogglesStatsWithoutQuitting(keyEquivalentFirst: Bool, connecting: Bool) throws {
        let store = try IsolatedStore("stats-z-\(keyEquivalentFirst)-\(connecting)")
        defer { store.remove() }
        store.defaults.set(Data(#"{"ctrl":true,"alt":false,"shift":false,"cmd":false,"keyChar":"q"}"#.utf8),
                           forKey: "quitHotkey")
        store.defaults.set(Data(#"{"ctrl":true,"alt":false,"shift":false,"cmd":false,"keyChar":"z"}"#.utf8),
                           forKey: "statsHotkey")
        let quit = try #require(AppModel.persistedDecoded("quitHotkey", HotkeyChord.self, defaults: store.defaults))
        let stats = try #require(AppModel.persistedDecoded("statsHotkey", HotkeyChord.self, defaults: store.defaults))
        let (forwarder, backend, view) = ready()
        forwarder.quitHotkeyProvider = { quit }
        forwarder.statsHotkeyProvider = { stats }
        forwarder.initialConnectPending = connecting
        forwarder.isReady = !connecting
        let quits = Tally()
        let toggles = Tally()
        forwarder.onQuitHotkey = { quits.calls += 1 }
        forwarder.onCancelConnect = { quits.calls += 1 }
        forwarder.onStatsHotkey = { toggles.calls += 1 }
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: 1,
            windowNumber: 0, context: nil, characters: "\u{1a}", charactersIgnoringModifiers: "z",
            isARepeat: false, keyCode: 6))
        if keyEquivalentFirst { #expect(!view.performKeyEquivalent(with: event)) }
        #expect(quits.calls == 0)
        view.keyDown(with: event)
        #expect(quits.calls == 0)
        #expect(toggles.calls == 1)
        #expect(backend.keyboard.isEmpty)
        #expect(backend.texts.isEmpty)

        let stop = try key(.keyDown, kVK_ANSI_Q, mods: [.control], chars: "q", at: 2)
        if keyEquivalentFirst {
            #expect(view.performKeyEquivalent(with: stop))
        } else {
            view.keyDown(with: stop)
        }
        #expect(quits.calls == 1)
        #expect(toggles.calls == 1)
    }

    @Test func controlZFromCoreGraphicsDoesNotMatchQuit() throws {
        let raw = try #require(CGEvent(keyboardEventSource: nil, virtualKey: 6, keyDown: true))
        raw.flags = .maskControl
        raw.keyboardSetUnicodeString(stringLength: 1, unicodeString: [0x7A])
        let event = try #require(NSEvent(cgEvent: raw))
        let (forwarder, backend, view) = ready()
        let quits = Tally()
        let stats = Tally()
        forwarder.statsHotkeyProvider = {
            HotkeyChord(ctrl: true, alt: false, shift: false, cmd: false, keyChar: "z")
        }
        forwarder.onQuitHotkey = { quits.calls += 1 }
        forwarder.onStatsHotkey = { stats.calls += 1 }
        #expect(event.keyCode == 6)
        #expect(!view.performKeyEquivalent(with: event))
        view.keyDown(with: event)
        #expect(quits.calls == 0)
        #expect(stats.calls == 1)
        #expect(backend.keyboard.isEmpty)
    }

    @Test(arguments: [false, true])
    func controlZSurvivesResponderAndPresentationChanges(keyEquivalentFirst: Bool) throws {
        let forwarder = InputForwarder()
        let backend = InputRecordingBackend()
        let window = PointerFocusTestWindow(contentRect: .zero, styleMask: .borderless,
                                            backing: .buffered, defer: true)
        forwarder.attach(to: window)
        forwarder.setBackend(backend)
        defer { forwarder.detach() }
        let view = try #require(forwarder.inputView)
        forwarder.statsHotkeyProvider = {
            HotkeyChord(ctrl: true, alt: false, shift: false, cmd: false, keyChar: "z")
        }
        let quits = Tally(), stats = Tally()
        forwarder.onQuitHotkey = { quits.calls += 1 }
        forwarder.onCancelConnect = { quits.calls += 1 }
        forwarder.onStatsHotkey = { stats.calls += 1 }
        let event = try key(.keyDown, kVK_ANSI_Z, mods: [.control], chars: "z")
        let repeatEvent = try key(.keyDown, kVK_ANSI_Z, mods: [.control], chars: "z", isRepeat: true)
        for step in 0..<6 {
            switch step {
            case 1: #expect(window.makeFirstResponder(view))
            case 2: forwarder.isReady = true; forwarder.initialConnectPending = false
            case 3: forwarder.setMiniPlayer(true)
            case 4: forwarder.windowResignedKey(); #expect(window.makeFirstResponder(nil))
            case 5: forwarder.setMiniPlayer(false); #expect(window.makeFirstResponder(view))
            default: break
            }
            forwarder.heldModifierVKs = [0xA0, 0xA2, 0xA4, 0x5B]
            for vk in forwarder.heldModifierVKs { forwarder.releases.hold(.key(VKScanCode(vk: vk))) }
            backend.inputResult = -2
            if keyEquivalentFirst { #expect(!view.performKeyEquivalent(with: event)) }
            view.keyDown(with: event)
            #expect(stats.calls == step + 1)
            #expect(!forwarder.releases.pending.isEmpty)
            if keyEquivalentFirst { #expect(!view.performKeyEquivalent(with: repeatEvent)) }
            view.keyDown(with: repeatEvent)
            #expect(stats.calls == step + 1)
            #expect(quits.calls == 0)
        }
    }

    @Test func aRetiredStreamViewCannotInvokeItsOldQuitProvider() throws {
        let old = InputForwarder()
        let oldWindow = PointerFocusTestWindow(contentRect: .zero, styleMask: .borderless,
                                               backing: .buffered, defer: true)
        old.attach(to: oldWindow)
        old.setBackend(InputRecordingBackend())
        let oldView = try #require(old.inputView)
        let quits = Tally(), stats = Tally()
        old.quitHotkeyProvider = {
            HotkeyChord(ctrl: true, alt: false, shift: false, cmd: false, keyChar: "z")
        }
        old.onCancelConnect = { quits.calls += 1 }
        old.onQuitHotkey = { quits.calls += 1 }
        old.detach()
        #expect(oldView.delegate == nil)

        let (current, _, currentView) = ready()
        defer { current.detach() }
        current.statsHotkeyProvider = old.quitHotkeyProvider
        current.onQuitHotkey = { quits.calls += 1 }
        current.onStatsHotkey = { stats.calls += 1 }
        let event = try key(.keyDown, kVK_ANSI_Z, mods: [.control], chars: "z")
        #expect(!oldView.performKeyEquivalent(with: event))
        oldView.keyDown(with: event)
        #expect(!currentView.performKeyEquivalent(with: event))
        currentView.keyDown(with: event)
        #expect(quits.calls == 0)
        #expect(stats.calls == 1)
    }

    @Test func quitAndStatsChordsStayOnTheMac() throws {
        let (forwarder, backend, view) = ready()
        let quits = Tally()
        let stats = Tally()
        forwarder.onQuitHotkey = { quits.calls += 1 }
        forwarder.onStatsHotkey = { stats.calls += 1 }
        view.keyDown(with: try key(.keyDown, kVK_ANSI_Q, mods: [.control], chars: "q"))
        view.keyDown(with: try key(.keyDown, kVK_ANSI_Z, mods: [.control], chars: "z"))
        view.keyDown(with: try key(.keyDown, kVK_ANSI_Z, mods: [.control], chars: "z", isRepeat: true))
        #expect(quits.calls == 1)
        #expect(stats.calls == 1)
        #expect(!backend.keyboard.contains { $0.keyCode == wire(0x51) || $0.keyCode == wire(0x5A) })
    }

    @Test func bookmarkChordWithoutAHandlerIsAKey() throws {
        let (forwarder, backend, view) = ready()
        view.keyDown(with: try key(.keyDown, kVK_ANSI_B, mods: [.control], chars: "b"))
        #expect(forwarder.heldKeys == [0x42])
        #expect(backend.keyboard.last == .init(keyCode: wire(0x42), action: down,
                                               modifiers: Int8(StreamProtocol.MODIFIER_CTRL), flags: 0))
    }

    @Test func pointerChordIsConsumedInFullScreen() throws {
        let (forwarder, backend, view) = ready()
        view.keyDown(with: try key(.keyDown, kVK_ANSI_P, mods: [.control], chars: "p"))
        #expect(forwarder.heldKeys.isEmpty)
        #expect(backend.keyboard.isEmpty)
    }

    @Test func miniPlayerChordToggles() throws {
        let (forwarder, backend, view) = ready()
        let toggles = Tally()
        forwarder.onMiniPlayerHotkey = { toggles.calls += 1 }
        forwarder.modifiersNeedResync = false
        view.keyDown(with: try key(.keyDown, kVK_ANSI_M, mods: [.control], chars: "m"))
        #expect(toggles.calls == 1)
        #expect(backend.keyboard.isEmpty)
    }

    // MARK: The view's own routing

    @Test func viewClaimsCommandEquivalentsOnlyWhenTheyAreTheGames() throws {
        let (forwarder, backend, view) = ready()
        let commandW = try key(.keyDown, kVK_ANSI_W, mods: [.command], chars: "w")
        #expect(!view.performKeyEquivalent(with: commandW))
        let window = PointerFocusTestWindow()
        window.contentView = view
        window.makeFirstResponder(view)
        forwarder.inputView = view
        forwarder.window = window
        forwarder.captureSysKeys = true
        #expect(view.performKeyEquivalent(with: commandW))
        #expect(backend.keyboard.last?.keyCode == wire(0x57))
        #expect(backend.keyboard.last?.modifiers == Int8(StreamProtocol.MODIFIER_META))
    }

    /// Without a live tracking area AppKit never delivers mouseMoved; a resize replaces it.
    @Test func trackingAreaIsReplacedNotStacked() {
        let view = StreamInputView(frame: NSRect(x: 0, y: 0, width: 64, height: 32))
        view.updateTrackingAreas()
        view.updateTrackingAreas()
        #expect(view.trackingAreas.count == 1)
        let options = view.trackingAreas.first?.options ?? []
        #expect(options.isSuperset(of: [.mouseMoved, .activeAlways, .mouseEnteredAndExited]))
    }

    @Test func viewAcceptsTheActivatingClickOnlyForTheMiniPlayer() {
        let forwarder = InputForwarder()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
                              styleMask: .borderless, backing: .buffered, defer: true)
        forwarder.attach(to: window)
        defer { forwarder.detach() }
        let view = forwarder.inputView
        #expect(view?.acceptsFirstMouse(for: nil) == false)
        #expect(view?.acceptsFirstResponder == true)
        forwarder.setMiniPlayer(true)
        #expect(view?.acceptsFirstMouse(for: nil) == true)
        forwarder.setMiniPlayer(false)
        #expect(view?.acceptsFirstMouse(for: nil) == false)
    }
}

/// ⌃B is a bookmark only while telemetry runs; otherwise it is the game's.
@MainActor
struct BookmarkChordTelemetryTests {
    @MainActor
    private final class Tally { var calls = 0 }

    /// One ⌃B with a handler wired: the bookmark count and the keys sent.
    private func pressBookmark(telemetryEnabled: Bool) throws -> (marks: Int, sent: [KeyboardSend]) {
        let forwarder = InputForwarder()
        let backend = InputRecordingBackend()
        forwarder.setBackend(backend)
        forwarder.isReady = true
        forwarder.bookmarkEnabled = { telemetryEnabled }
        let marks = Tally()
        forwarder.onBookmarkHotkey = { marks.calls += 1 }
        let view = StreamInputView()
        view.delegate = forwarder
        view.interpretTextEvent = { view, event in
            view.insertText(event.characters ?? "", replacementRange: NSRange(location: NSNotFound, length: 0))
        }
        view.keyDown(with: try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.control], timestamp: 1, windowNumber: 0,
            context: nil, characters: "b", charactersIgnoringModifiers: "b", isARepeat: false,
            keyCode: UInt16(kVK_ANSI_B))))
        return (marks.calls, backend.keyboard)
    }

    @Test func withTelemetryOnTheChordIsABookmark() throws {
        let result = try pressBookmark(telemetryEnabled: true)
        #expect(result.marks == 1)
        #expect(result.sent.isEmpty)
    }

    @Test func withTelemetryOffTheChordReachesThePC() throws {
        let result = try pressBookmark(telemetryEnabled: false)
        #expect(result.marks == 0)
        #expect(result.sent.last == .init(keyCode: VKScanCode(vk: 0x42).wireCode,
                                          action: Int8(StreamProtocol.KEY_ACTION_DOWN),
                                          modifiers: Int8(StreamProtocol.MODIFIER_CTRL), flags: 0))
    }
}
