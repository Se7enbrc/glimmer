// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Keyboard ownership and local shortcuts must survive layout and connection changes.

import GlimmerEngine
import AppKit
import Carbon.HIToolbox
import Testing
@testable import Glimmer

@MainActor
private func key(_ type: NSEvent.EventType, _ keyCode: Int, mods: NSEvent.ModifierFlags = [],
                 chars: String = "w", isRepeat: Bool = false, at timestamp: TimeInterval = 1) throws -> NSEvent {
    try #require(NSEvent.keyEvent(
        with: type, location: .zero, modifierFlags: mods, timestamp: timestamp,
        windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
        isARepeat: isRepeat, keyCode: UInt16(keyCode)))
}

@MainActor
struct CommandKeyUpTests {

    @Test func sameEventDeliveredTwiceIsADuplicate() throws {
        let forwarder = InputForwarder()
        forwarder.backend = InputRecordingBackend()
        let event = try key(.keyUp, kVK_ANSI_D, mods: [.command], at: 100)
        #expect(forwarder.isDuplicateKeyUp(event) == false)
        #expect(forwarder.isDuplicateKeyUp(event))
    }

    @Test func differentKeyOrTimeIsNotADuplicate() throws {
        let forwarder = InputForwarder()
        forwarder.backend = InputRecordingBackend()
        #expect(try forwarder.isDuplicateKeyUp(key(.keyUp, kVK_ANSI_D, mods: [.command], at: 100)) == false)
        #expect(try forwarder.isDuplicateKeyUp(key(.keyUp, kVK_ANSI_A, mods: [.command], at: 100)) == false)
        #expect(try forwarder.isDuplicateKeyUp(key(.keyUp, kVK_ANSI_A, mods: [.command], at: 101)) == false)
    }
}

/// A key held from before ⌘ went down was forwarded, so its release must be
/// forwarded too, even with sys-key capture off.
@MainActor
struct HeldKeyReleaseUnderCommandTests {

    @Test func heldKeyIsReleasedUnderCommand() throws {
        let forwarder = InputForwarder()
        forwarder.backend = InputRecordingBackend()
        forwarder.isReady = true
        let view = StreamInputView()
        forwarder.streamView(view, handleKeyDown: try key(.keyDown, kVK_ANSI_W))
        #expect(forwarder.heldKeys == [0x57])
        forwarder.streamView(view, handleKeyUp: try key(.keyUp, kVK_ANSI_W, mods: [.command]))
        #expect(forwarder.heldKeys.isEmpty)
    }

    @Test func unforwardedCommandKeyIsNeverHeld() throws {
        let forwarder = InputForwarder()
        forwarder.backend = InputRecordingBackend()
        forwarder.isReady = true
        let view = StreamInputView()
        forwarder.streamView(view, handleKeyDown: try key(.keyDown, kVK_ANSI_W, mods: [.command]))
        #expect(forwarder.heldKeys.isEmpty)
        forwarder.streamView(view, handleKeyUp: try key(.keyUp, kVK_ANSI_W, mods: [.command]))
        #expect(forwarder.heldKeys.isEmpty)
    }
}

/// With ⌘ shortcuts sent to the game, a ⌘ key equivalent goes to the PC only
/// while the stream is key; otherwise it stays the Mac's.
@MainActor
struct CommandKeyEquivalentTests {

    private func commandTab() throws -> NSEvent {
        try key(.keyDown, kVK_Tab, mods: [.command], chars: "\t")
    }

    private func forwarder(optedIn: Bool, window: NSWindow) -> InputForwarder {
        let forwarder = InputForwarder()
        forwarder.backend = InputRecordingBackend()
        forwarder.isReady = true
        forwarder.captureSysKeys = optedIn
        let view = StreamInputView()
        window.contentView = view
        window.makeFirstResponder(view)
        forwarder.inputView = view
        forwarder.window = window
        return forwarder
    }

    @Test func focusedStreamSendsCommandChordsToThePC() throws {
        let window = PointerFocusTestWindow()
        let forwarder = forwarder(optedIn: true, window: window)
        #expect(forwarder.streamView(StreamInputView(), handleKeyEquivalent: try commandTab()))
        #expect(forwarder.heldKeys.count == 1)
    }

    @Test func commandChordsStayWithTheMacUnlessOptedInAndFocused() throws {
        for (optedIn, focused) in [(false, true), (true, false), (false, false)] {
            let window = PointerFocusTestWindow()
            window.focused = focused
            let forwarder = forwarder(optedIn: optedIn, window: window)
            #expect(!forwarder.streamView(StreamInputView(), handleKeyEquivalent: try commandTab()))
            #expect(forwarder.heldKeys.isEmpty)
        }
    }

    /// Left ⌘ down, as its flagsChanged reports it (device bit 0x8).
    private func leftCommandDown() throws -> NSEvent {
        let flags = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x8)
        return try key(.flagsChanged, kVK_Command, mods: flags, chars: "")
    }

    /// A background stream must not send a stray Win tap to the PC.
    @Test func commandIsNotTheWinKeyWhileTheWindowIsNotKey() throws {
        let window = PointerFocusTestWindow()
        window.focused = false
        let forwarder = forwarder(optedIn: true, window: window)
        forwarder.streamView(StreamInputView(), handleFlagsChanged: try leftCommandDown())
        #expect(forwarder.heldModifierVKs.isEmpty)
        #expect(forwarder.modifierByte(from: [.command]) == 0)
    }

    @Test func focusedCommandIsTheWinKeyUntilFocusEnds() throws {
        let window = PointerFocusTestWindow()
        let forwarder = forwarder(optedIn: true, window: window)
        forwarder.streamView(StreamInputView(), handleFlagsChanged: try leftCommandDown())
        #expect(forwarder.heldModifierVKs == [0x5B])
        window.focused = false
        forwarder.windowResignedKey()
        #expect(forwarder.heldModifierVKs.isEmpty)
    }
}

/// A reconnect's new session starts with nothing held on the PC, so what the
/// forwarder believes is held must follow it there.
@MainActor
struct ReconnectHeldInputTests {

    @Test func modifierPressedDuringTheGapReachesThePCWithTheNextKey() throws {
        let forwarder = InputForwarder()
        forwarder.backend = InputRecordingBackend()
        let view = StreamInputView()
        forwarder.streamView(view, handleFlagsChanged: try key(.flagsChanged, kVK_Shift, mods: [.shift], chars: ""))
        #expect(forwarder.heldModifierVKs.isEmpty)
        forwarder.isReady = true
        forwarder.streamView(view, handleKeyDown: try key(.keyDown, kVK_ANSI_W, mods: [.shift]))
        #expect(forwarder.heldModifierVKs == [0xA0])  // VK_LSHIFT
        #expect(forwarder.heldKeys == [0x57])
    }

    @Test func reconnectReleasesWhatTheGapLeftHeld() throws {
        let forwarder = InputForwarder()
        forwarder.backend = InputRecordingBackend()
        defer { forwarder.setReady(false) }
        let view = StreamInputView()
        forwarder.setReady(true)
        forwarder.streamView(view, handleFlagsChanged: try key(.flagsChanged, kVK_Control, mods: [.control], chars: ""))
        forwarder.streamView(view, handleKeyDown: try key(.keyDown, kVK_ANSI_W, mods: [.control]))
        forwarder.setReady(false)
        // W comes up during the gap, where no up can be sent.
        forwarder.streamView(view, handleKeyUp: try key(.keyUp, kVK_ANSI_W, mods: [.control], at: 2))
        #expect(forwarder.heldKeys.isEmpty)
        forwarder.setReady(true)
        #expect(forwarder.heldKeys.isEmpty)
        #expect(forwarder.heldModifierVKs.isEmpty)
        // Control is still down on the Mac: the next key tells the new session.
        forwarder.streamView(view, handleKeyDown: try key(.keyDown, kVK_ANSI_A, mods: [.control], at: 3))
        #expect(forwarder.heldModifierVKs == [0xA2])  // VK_LCONTROL
    }

    @Test func toolPostedShortcutLeavesNoModifierHeld() throws {
        let forwarder = InputForwarder()
        forwarder.backend = InputRecordingBackend()
        forwarder.isReady = true
        let view = StreamInputView()
        forwarder.streamView(view, handleKeyDown: try key(.keyDown, kVK_ANSI_A, chars: "a"))
        forwarder.streamView(view, handleKeyUp: try key(.keyUp, kVK_ANSI_A, chars: "a", at: 2))
        // A posted ⌃C: its flags carry ⌃ but no flagsChanged came first.
        forwarder.streamView(view, handleKeyDown: try key(.keyDown, kVK_ANSI_C, mods: [.control], chars: "c", at: 3))
        #expect(forwarder.heldModifierVKs.isEmpty)
        #expect(forwarder.heldKeys == [0x43])
    }
}

@MainActor
struct MissingModifierReleaseTests {
    @MainActor
    private final class Tally { var calls = 0 }

    @Test func interruptedMiniPlayerChordReleasesControlBeforeBareEscape() throws {
        let forwarder = InputForwarder()
        forwarder.backend = InputRecordingBackend()
        let backend = InputRecordingBackend()
        let toggles = Tally()
        forwarder.backend = backend
        forwarder.isReady = true
        forwarder.onMiniPlayerHotkey = { toggles.calls += 1 }
        let view = StreamInputView()
        forwarder.streamView(view, handleFlagsChanged: try key(.flagsChanged, kVK_Control, mods: [.control]))
        forwarder.streamView(view, handleKeyDown: try key(.keyDown, kVK_ANSI_M, mods: [.control], chars: "m"))
        #expect(toggles.calls == 1)
        #expect(forwarder.heldModifierVKs == [0xA2])
        #expect(backend.keyboard.count == 1)

        // The posted chord was interrupted before its Control-up arrived.
        forwarder.streamView(view, handleKeyDown: try key(.keyDown, kVK_Escape, chars: "\u{1b}", at: 2))
        forwarder.streamView(view, handleKeyUp: try key(.keyUp, kVK_Escape, chars: "\u{1b}", at: 3))
        #expect(forwarder.heldModifierVKs.isEmpty)
        #expect(backend.keyboard.map(\.keyCode) == [wire(0xA2), wire(0xA2), wire(0x1B), wire(0x1B)])
        #expect(backend.keyboard.map(\.action) == [down, up, down, up])
        #expect(backend.keyboard.suffix(3).allSatisfy { $0.modifiers == 0 })
    }

    @Test func heldEscapeRepeatRecoversControlWithoutAnotherEscapeDown() throws {
        let forwarder = InputForwarder()
        forwarder.backend = InputRecordingBackend()
        let backend = InputRecordingBackend()
        forwarder.backend = backend
        forwarder.isReady = true
        let view = StreamInputView()
        forwarder.streamView(view, handleFlagsChanged: try key(.flagsChanged, kVK_Control, mods: [.control]))
        forwarder.streamView(view, handleKeyDown: try key(.keyDown, kVK_Escape, mods: [.control]))
        forwarder.streamView(view, handleKeyDown: try key(.keyDown, kVK_Escape, isRepeat: true, at: 2))
        #expect(forwarder.heldModifierVKs.isEmpty)
        #expect(backend.keyboard.map(\.keyCode) == [wire(0xA2), wire(0x1B), wire(0xA2)])
        #expect(backend.keyboard.map(\.action) == [down, down, up])
    }

    @Test func keyUpRecoversMissingModifierReleaseAndPreservesEscapeTap() throws {
        let forwarder = InputForwarder()
        forwarder.backend = InputRecordingBackend()
        let backend = InputRecordingBackend()
        forwarder.backend = backend
        forwarder.isReady = true
        forwarder.isWindowMode = true
        forwarder.isMouseCaptured = true
        defer { forwarder.cancelEscapeHold() }
        let view = StreamInputView()
        let rightControl = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.control.rawValue | 0x2000)
        forwarder.streamView(view, handleFlagsChanged: try key(.flagsChanged, kVK_RightControl, mods: rightControl))
        forwarder.streamView(view, handleKeyDown: try key(.keyDown, kVK_Escape, mods: [.control]))
        #expect(forwarder.heldModifierVKs == [0xA3])
        #expect(forwarder.escapeHoldTask == nil)
        forwarder.streamView(view, handleKeyUp: try key(.keyUp, kVK_Escape, at: 2))
        #expect(forwarder.escapeHoldTask == nil)
        #expect(forwarder.heldModifierVKs.isEmpty)
        #expect(forwarder.heldKeys.isEmpty)
        #expect(backend.keyboard.map(\.keyCode) == [wire(0xA3), wire(0x1B), wire(0xA3), wire(0x1B)])
        #expect(backend.keyboard.map(\.action) == [down, down, up, up])
    }

    private var down: Int8 { Int8(StreamProtocol.KEY_ACTION_DOWN) }
    private var up: Int8 { Int8(StreamProtocol.KEY_ACTION_UP) }
    private func wire(_ vk: Int16) -> Int16 { VKScanCode(vk: vk).wireCode }
}

@MainActor
struct ModifiedEscapeHoldTests {
    @Test(arguments: [NSEvent.ModifierFlags.command, .control, .option, .shift, .function])
    func modifiedEscapeDoesNotArmPointerRelease(modifier: NSEvent.ModifierFlags) throws {
        let forwarder = capturedForwarder()
        let view = StreamInputView()
        forwarder.streamView(view, handleKeyDown: try key(.keyDown, kVK_Escape, mods: modifier))
        #expect(forwarder.escapeHoldTask == nil)
        #expect(forwarder.heldKeys.isEmpty == modifier.contains(.command))
    }

    @Test(arguments: [NSEvent.ModifierFlags.command, .control])
    func modifierPressedDuringEscapeHoldCancelsRelease(modifier: NSEvent.ModifierFlags) throws {
        let forwarder = capturedForwarder()
        let view = StreamInputView()
        defer { forwarder.cancelEscapeHold() }
        forwarder.streamView(view, handleKeyDown: try key(.keyDown, kVK_Escape))
        #expect(forwarder.escapeHoldTask != nil)
        let keyCode = modifier.contains(.command) ? kVK_Command : kVK_Control
        forwarder.streamView(view, handleFlagsChanged: try key(.flagsChanged, keyCode, mods: modifier, at: 2))
        #expect(forwarder.escapeHoldTask == nil)
        #expect(forwarder.heldKeys == [0x1B])
        forwarder.streamView(view, handleFlagsChanged: try key(.flagsChanged, keyCode, at: 3))
        #expect(forwarder.escapeHoldTask == nil)
        forwarder.streamView(view, handleKeyUp: try key(.keyUp, kVK_Escape, at: 4))
        #expect(forwarder.heldKeys.isEmpty)
    }

    @Test func clientChordCancelsEscapeHoldBeforeItsEarlyReturn() throws {
        let forwarder = capturedForwarder()
        let view = StreamInputView()
        defer { forwarder.cancelEscapeHold() }
        forwarder.streamView(view, handleKeyDown: try key(.keyDown, kVK_Escape))
        #expect(forwarder.escapeHoldTask != nil)
        forwarder.streamView(view, handleKeyDown: try key(.keyDown, kVK_ANSI_M, mods: [.control], chars: "m", at: 2))
        #expect(forwarder.escapeHoldTask == nil)
        #expect(forwarder.heldKeys == [0x1B])
    }

    @Test func bareEscapeTapStillForwardsImmediatelyAndCancelsHold() throws {
        let forwarder = capturedForwarder()
        let backend = InputRecordingBackend()
        forwarder.backend = backend
        forwarder.isReady = true
        let view = StreamInputView()
        defer { forwarder.cancelEscapeHold() }
        forwarder.streamView(view, handleKeyDown: try key(.keyDown, kVK_Escape))
        #expect(forwarder.escapeHoldTask != nil)
        #expect(backend.keyboard.map(\.keyCode) == [VKScanCode(vk: 0x1B).wireCode])
        #expect(backend.keyboard.first?.action == Int8(StreamProtocol.KEY_ACTION_DOWN))
        forwarder.streamView(view, handleKeyUp: try key(.keyUp, kVK_Escape, at: 2))
        #expect(forwarder.escapeHoldTask == nil)
        #expect(backend.keyboard.last?.action == Int8(StreamProtocol.KEY_ACTION_UP))
        #expect(backend.keyboard.count == 2)
    }

    private func capturedForwarder() -> InputForwarder {
        let forwarder = InputForwarder()
        forwarder.backend = InputRecordingBackend()
        forwarder.isReady = true
        forwarder.isWindowMode = true
        forwarder.isMouseCaptured = true
        return forwarder
    }
}

@MainActor
struct HostKeyFlagsTests {

    @Test func yenAndBackslashAreHeldAsDifferentKeys() throws {
        let forwarder = InputForwarder()
        forwarder.backend = InputRecordingBackend()
        forwarder.isReady = true
        let view = StreamInputView()
        forwarder.streamView(view, handleKeyDown: try key(.keyDown, kVK_JIS_Yen))
        forwarder.streamView(view, handleKeyDown: try key(.keyDown, kVK_ANSI_Backslash))
        #expect(forwarder.heldKeys.count == 2)
        forwarder.streamView(view, handleKeyUp: try key(.keyUp, kVK_JIS_Yen, at: 2))
        #expect(forwarder.heldKeys == [0xDC])
    }

    @Test func unmappedKeyIsNotedOncePerSession() throws {
        let forwarder = InputForwarder()
        forwarder.backend = InputRecordingBackend()
        forwarder.isReady = true
        let view = StreamInputView()
        forwarder.streamView(view, handleKeyDown: try key(.keyDown, kVK_Function, chars: ""))
        forwarder.streamView(view, handleKeyDown: try key(.keyDown, kVK_Function, chars: "", at: 2))
        #expect(forwarder.heldKeys.isEmpty)
        #expect(forwarder.loggedUnmappedKeyCodes == [UInt16(kVK_Function)])
    }
}

/// Until the first connection is live the invisible stream window has key
/// focus, so a bare Esc must cancel the connect; after that it is game input.
@MainActor
struct ConnectEscapeTests {

    @MainActor
    private final class Tally { var calls = 0 }

    @Test func bareEscCancelsOnlyUntilTheStreamIsLive() throws {
        let forwarder = InputForwarder()
        forwarder.backend = InputRecordingBackend()
        let quits = Tally()
        let cancels = Tally()
        forwarder.onQuitHotkey = { quits.calls += 1 }
        forwarder.onCancelConnect = { cancels.calls += 1 }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
                              styleMask: .borderless, backing: .buffered, defer: true)
        forwarder.attach(to: window)
        defer { forwarder.detach() }
        let view = try #require(forwarder.inputView)
        forwarder.window = nil // Test responder delivery independently of a visible window.
        let quitChord = try key(.keyDown, kVK_ANSI_Q, mods: [.control], chars: "q", at: 4)

        forwarder.streamView(view, handleKeyDown: try key(.keyDown, kVK_Escape, mods: [.shift]))
        #expect(cancels.calls == 0)
        forwarder.streamView(view, handleKeyDown: try key(.keyDown, kVK_Escape))
        #expect(cancels.calls == 1)
        forwarder.streamView(view, handleKeyDown: quitChord)
        #expect(cancels.calls == 2)
        #expect(quits.calls == 0)

        forwarder.setReady(true)
        forwarder.streamView(view, handleKeyDown: try key(.keyDown, kVK_Escape, at: 2))
        #expect(cancels.calls == 2)
        #expect(forwarder.heldKeys == [0x1B])
        // A reconnect gap does not turn Esc back into cancel.
        forwarder.setReady(false)
        forwarder.streamView(view, handleKeyDown: try key(.keyDown, kVK_Escape, at: 3))
        forwarder.streamView(view, handleKeyDown: quitChord)
        #expect(cancels.calls == 2)
        #expect(quits.calls == 1)
    }
}

/// Client chords compare the typed character, falling back to the key's US
/// position only when the layout types something outside ASCII.
@MainActor
struct HotkeyChordLayoutTests {

    private let quit = HotkeyChord.defaultQuit  // ⌃Q

    private func matches(_ keyCode: Int, typing chars: String) throws -> Bool {
        let mods: NSEvent.ModifierFlags = [.control]
        return quit.matches(event: try key(.keyDown, keyCode, mods: mods, chars: chars), modifiers: mods)
    }

    @Test func anUnassignedChordCannotMatchAnEmptyKeyEvent() throws {
        let unassigned = HotkeyChord(ctrl: false, alt: false, shift: false, cmd: false, keyChar: "")
        let event = try key(.keyDown, kVK_Function, chars: "")
        #expect(unassigned.matchKind(event: event, modifiers: []) == nil)
    }

    @Test func nonLatinLayoutMatchesByPosition() throws {
        #expect(try matches(kVK_ANSI_Q, typing: "й"))
        #expect(try matches(kVK_ANSI_W, typing: "ц") == false)
    }

    @Test func latinLayoutKeepsItsOwnLetters() throws {
        // AZERTY: the key in the US A position types Q, and the US Q position types A.
        #expect(try matches(kVK_ANSI_A, typing: "q"))
        #expect(try matches(kVK_ANSI_Q, typing: "a") == false)
    }

    @Test func matchKindPreservesCharacterAndPositionRules() throws {
        let mods: NSEvent.ModifierFlags = [.control]
        let cases: [(Int, String, HotkeyChord.MatchKind?)] = [
            (kVK_ANSI_A, "q", .character), (kVK_ANSI_Q, "q", .character),
            (kVK_ANSI_Q, "й", .keyPositionFallback), (kVK_ANSI_W, "ц", nil),
            (kVK_ANSI_Q, "a", nil), (kVK_ANSI_Q, "", nil)
        ]
        for (code, text, expected) in cases {
            let event = try key(.keyDown, code, mods: mods, chars: text)
            #expect(quit.matchKind(event: event, modifiers: mods) == expected)
            #expect(quit.matches(event: event, modifiers: mods) == (expected != nil))
            #expect(quit.matchKind(event: event, modifiers: [.control, .shift]) == nil)
        }
    }
}

@MainActor
struct QuitHotkeyDiagnosticTests {
    private func entries(after previousID: UInt64?) -> [LogEntry] {
        LogStore.shared.snapshot().filter { entry in
            (previousID.map { entry.id > $0 } ?? true)
                && entry.category == "Stream.Input" && entry.message.hasPrefix("Quit hotkey matched:")
        }
    }

    @Test(arguments: [false, true], [false, true])
    func matchedQuitLogsContextWithoutKeystrokePayload(keyEquivalent: Bool, fallback: Bool) throws {
        let forwarder = InputForwarder()
        let view = StreamInputView()
        view.delegate = forwarder
        let chord = HotkeyChord(ctrl: true, alt: true, shift: true, cmd: true, keyChar: "q")
        var providerCalls = 0
        forwarder.quitHotkeyProvider = {
            providerCalls += 1
            return providerCalls == 1 ? chord : .defaultStats
        }
        forwarder.inputGeneration = 37
        forwarder.isWindowMode = !fallback
        forwarder.isMiniPlayer = fallback
        var quits = 0
        forwarder.onQuitHotkey = { quits += 1 }
        let event = try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.control, .option, .shift, .command],
            timestamp: 1, windowNumber: 0, context: nil, characters: "private-event-payload",
            charactersIgnoringModifiers: fallback ? "й" : "q", isARepeat: false,
            keyCode: UInt16(kVK_ANSI_Q)))
        let before = LogStore.shared.snapshot().last?.id
        if keyEquivalent {
            #expect(view.performKeyEquivalent(with: event))
        } else {
            view.keyDown(with: event)
        }
        #expect(providerCalls == 1)
        #expect(quits == 1)
        let logged = entries(after: before)
        try #require(logged.count == 1)
        let entry = try #require(logged.first)
        let expectedEntry = keyEquivalent ? "performKeyEquivalent" : "keyDown"
        let expectedMatch = fallback ? "key-position-fallback" : "character"
        let expected = "Quit hotkey matched: entry=\(expectedEntry) match=\(expectedMatch) chord=⌃⌥⇧⌘Q "
            + "windowMode=\(!fallback) generation=37 miniPlayer=\(fallback)"
        #expect(entry.level == .info)
        #expect(entry.message == expected)
        #expect(entry.redactedMessage == nil)
        #expect(entry.shareable.hasSuffix(expected))
        for rendered in [entry.message, entry.redactedMessage ?? entry.message] {
            for payload in ["keyCode", "characters", "modifiers", "private-event-payload", "й",
                            String(event.keyCode), String(event.modifierFlags.rawValue)] {
                #expect(rendered.contains(payload) == false)
            }
        }
    }

    @Test func unmatchedAndRepeatedQuitEventsDoNotLog() throws {
        let forwarder = InputForwarder()
        var quits = 0
        forwarder.onQuitHotkey = { quits += 1 }
        let before = LogStore.shared.snapshot().last?.id
        let unmatched = try key(.keyDown, kVK_ANSI_Z, mods: [.control], chars: "z")
        let repeatQuit = try key(.keyDown, kVK_ANSI_Q, mods: [.control], chars: "q", isRepeat: true)
        let keyUp = try key(.keyUp, kVK_ANSI_Q, mods: [.control], chars: "q")
        for entry in ["keyDown", "performKeyEquivalent"] {
            #expect(forwarder.consumeStopShortcut(unmatched, entry: entry) == false)
            #expect(forwarder.consumeStopShortcut(repeatQuit, entry: entry))
            #expect(forwarder.consumeStopShortcut(keyUp, entry: entry) == false)
        }
        #expect(quits == 0)
        #expect(entries(after: before).isEmpty)
    }
}
