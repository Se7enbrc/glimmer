//
//  CommandKeyUpTests.swift
//
//  The forwarder's keyboard path: the ⌘-held key-up de-dup (#86), which keys
//  and modifiers the PC is told are held across ⌘, reconnects and JIS keys,
//  Esc before the stream is live, and client chords on non-Latin layouts.
//

import AppKit
import Carbon.HIToolbox
import Testing
@testable import Glimmer

@MainActor
private func key(_ type: NSEvent.EventType, _ keyCode: Int, mods: NSEvent.ModifierFlags = [],
                 chars: String = "w", at timestamp: TimeInterval = 1) throws -> NSEvent {
    try #require(NSEvent.keyEvent(
        with: type, location: .zero, modifierFlags: mods, timestamp: timestamp,
        windowNumber: 0, context: nil, characters: chars, charactersIgnoringModifiers: chars,
        isARepeat: false, keyCode: UInt16(keyCode)))
}

@MainActor
struct CommandKeyUpTests {

    @Test func sameEventDeliveredTwiceIsADuplicate() throws {
        let forwarder = InputForwarder()
        let event = try key(.keyUp, kVK_ANSI_D, mods: [.command], at: 100)
        #expect(forwarder.isDuplicateKeyUp(event) == false)
        #expect(forwarder.isDuplicateKeyUp(event))
    }

    @Test func differentKeyOrTimeIsNotADuplicate() throws {
        let forwarder = InputForwarder()
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
        forwarder.isReady = true
        let view = StreamInputView()
        forwarder.streamView(view, handleKeyDown: try key(.keyDown, kVK_ANSI_W))
        #expect(forwarder.heldKeys == [0x57])
        forwarder.streamView(view, handleKeyUp: try key(.keyUp, kVK_ANSI_W, mods: [.command]))
        #expect(forwarder.heldKeys.isEmpty)
    }

    @Test func unforwardedCommandKeyIsNeverHeld() throws {
        let forwarder = InputForwarder()
        forwarder.isReady = true
        let view = StreamInputView()
        forwarder.streamView(view, handleKeyDown: try key(.keyDown, kVK_ANSI_W, mods: [.command]))
        #expect(forwarder.heldKeys.isEmpty)
        forwarder.streamView(view, handleKeyUp: try key(.keyUp, kVK_ANSI_W, mods: [.command]))
        #expect(forwarder.heldKeys.isEmpty)
    }
}

/// With ⌘ shortcuts sent to the game, a ⌘ key equivalent goes to the PC only
/// while the stream holds the pointer; otherwise it stays the Mac's.
@MainActor
struct CommandKeyEquivalentTests {

    private func commandTab() throws -> NSEvent {
        try key(.keyDown, kVK_Tab, mods: [.command], chars: "\t")
    }

    private func forwarder(optedIn: Bool, captured: Bool) -> InputForwarder {
        let forwarder = InputForwarder()
        forwarder.isReady = true
        forwarder.captureSysKeys = optedIn
        forwarder.isMouseCaptured = captured
        return forwarder
    }

    @Test func capturedStreamSendsCommandChordsToThePC() throws {
        let forwarder = forwarder(optedIn: true, captured: true)
        #expect(forwarder.streamView(StreamInputView(), handleKeyEquivalent: try commandTab()))
        #expect(forwarder.heldKeys.count == 1)
    }

    @Test func commandChordsStayWithTheMacUnlessOptedInAndCaptured() throws {
        for (optedIn, captured) in [(false, true), (true, false), (false, false)] {
            let forwarder = forwarder(optedIn: optedIn, captured: captured)
            #expect(!forwarder.streamView(StreamInputView(), handleKeyEquivalent: try commandTab()))
            #expect(forwarder.heldKeys.isEmpty)
        }
    }

    /// Left ⌘ down, as its flagsChanged reports it (device bit 0x8).
    private func leftCommandDown() throws -> NSEvent {
        let flags = NSEvent.ModifierFlags(rawValue: NSEvent.ModifierFlags.command.rawValue | 0x8)
        return try key(.flagsChanged, kVK_Command, mods: flags, chars: "")
    }

    /// Opted in with the pointer free, ⌘ is the Mac's, so ⌘V pastes and ⌘-Tab
    /// leaves with no Win key held on the PC for a release to turn into Start.
    @Test func commandIsNotTheWinKeyWhileThePointerIsFree() throws {
        let forwarder = forwarder(optedIn: true, captured: false)
        forwarder.streamView(StreamInputView(), handleFlagsChanged: try leftCommandDown())
        #expect(forwarder.heldModifierVKs.isEmpty)
        #expect(forwarder.modifierByte(from: [.command]) == 0)
    }

    @Test func capturedCommandIsTheWinKeyUntilCaptureEnds() throws {
        let forwarder = forwarder(optedIn: true, captured: true)
        forwarder.streamView(StreamInputView(), handleFlagsChanged: try leftCommandDown())
        #expect(forwarder.heldModifierVKs == [0x5B])
        forwarder.exitCapturedMode()
        #expect(forwarder.heldModifierVKs.isEmpty)
    }
}

/// A reconnect's new session starts with nothing held on the PC, so what the
/// forwarder believes is held must follow it there.
@MainActor
struct ReconnectHeldInputTests {

    @Test func modifierPressedDuringTheGapReachesThePCWithTheNextKey() throws {
        let forwarder = InputForwarder()
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
        defer { forwarder.setReady(false) }
        let view = StreamInputView()
        forwarder.setReady(true)
        forwarder.streamView(view, handleFlagsChanged: try key(.flagsChanged, kVK_Control, mods: [.control], chars: ""))
        forwarder.streamView(view, handleKeyDown: try key(.keyDown, kVK_ANSI_W, mods: [.control]))
        forwarder.setReady(false)
        // W comes up during the gap, where no up can be sent.
        forwarder.streamView(view, handleKeyUp: try key(.keyUp, kVK_ANSI_W, mods: [.control], at: 2))
        #expect(forwarder.heldKeys == [0x57])
        forwarder.setReady(true)
        #expect(forwarder.heldKeys.isEmpty)
        #expect(forwarder.heldModifierVKs.isEmpty)
        // Control is still down on the Mac: the next key tells the new session.
        forwarder.streamView(view, handleKeyDown: try key(.keyDown, kVK_ANSI_A, mods: [.control], at: 3))
        #expect(forwarder.heldModifierVKs == [0xA2])  // VK_LCONTROL
    }

    @Test func toolPostedShortcutLeavesNoModifierHeld() throws {
        let forwarder = InputForwarder()
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
struct HostKeyFlagsTests {

    @Test func yenAndBackslashAreHeldAsDifferentKeys() throws {
        let forwarder = InputForwarder()
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
        forwarder.isReady = true
        let view = StreamInputView()
        forwarder.streamView(view, handleKeyDown: try key(.keyDown, kVK_Function))
        forwarder.streamView(view, handleKeyDown: try key(.keyDown, kVK_Function, at: 2))
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
        let quits = Tally()
        let cancels = Tally()
        forwarder.onQuitHotkey = { quits.calls += 1 }
        forwarder.onCancelConnect = { cancels.calls += 1 }
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 64, height: 64),
                              styleMask: .borderless, backing: .buffered, defer: true)
        forwarder.attach(to: window)
        defer { forwarder.detach() }
        let view = try #require(forwarder.inputView)
        let quitChord = try key(.keyDown, kVK_ANSI_Q, mods: [.control, .option], chars: "q", at: 4)

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

    private let quit = HotkeyChord.defaultQuit  // ⌃⌥Q

    private func matches(_ keyCode: Int, typing chars: String) throws -> Bool {
        let mods: NSEvent.ModifierFlags = [.control, .option]
        return quit.matches(event: try key(.keyDown, keyCode, mods: mods, chars: chars), modifiers: mods)
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
}
