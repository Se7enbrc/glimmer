//
//  CommandKeyUpTests.swift
//
//  Covers the ⌘-held key-up de-dup (#86): the responder chain and the local
//  monitor can both deliver one physical key-up; only the first may forward.
//

import AppKit
import Carbon.HIToolbox
import Testing
@testable import Glimmer

@MainActor
struct CommandKeyUpTests {

    private func keyUp(keyCode: Int, at timestamp: TimeInterval) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyUp, location: .zero, modifierFlags: [.command], timestamp: timestamp,
            windowNumber: 0, context: nil, characters: "d", charactersIgnoringModifiers: "d",
            isARepeat: false, keyCode: UInt16(keyCode)))
    }

    @Test func sameEventDeliveredTwiceIsADuplicate() throws {
        let forwarder = InputForwarder()
        let event = try keyUp(keyCode: kVK_ANSI_D, at: 100)
        #expect(forwarder.isDuplicateKeyUp(event) == false)
        #expect(forwarder.isDuplicateKeyUp(event))
    }

    @Test func differentKeyOrTimeIsNotADuplicate() throws {
        let forwarder = InputForwarder()
        #expect(try forwarder.isDuplicateKeyUp(keyUp(keyCode: kVK_ANSI_D, at: 100)) == false)
        #expect(try forwarder.isDuplicateKeyUp(keyUp(keyCode: kVK_ANSI_A, at: 100)) == false)
        #expect(try forwarder.isDuplicateKeyUp(keyUp(keyCode: kVK_ANSI_A, at: 101)) == false)
    }
}

/// A key held from before ⌘ went down was forwarded, so its release must be
/// forwarded too, even with sys-key capture off.
@MainActor
struct HeldKeyReleaseUnderCommandTests {

    private func key(_ type: NSEvent.EventType, keyCode: Int, mods: NSEvent.ModifierFlags) throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: type, location: .zero, modifierFlags: mods, timestamp: 1,
            windowNumber: 0, context: nil, characters: "w", charactersIgnoringModifiers: "w",
            isARepeat: false, keyCode: UInt16(keyCode)))
    }

    @Test func heldKeyIsReleasedUnderCommand() throws {
        let forwarder = InputForwarder()
        forwarder.isReady = true
        let view = StreamInputView()
        #expect(forwarder.streamView(view, handleKeyDown: try key(.keyDown, keyCode: kVK_ANSI_W, mods: [])))
        #expect(forwarder.heldKeys.count == 1)
        forwarder.streamView(view, handleKeyUp: try key(.keyUp, keyCode: kVK_ANSI_W, mods: [.command]))
        #expect(forwarder.heldKeys.isEmpty)
    }

    @Test func unforwardedCommandKeyUpIsIgnored() throws {
        let forwarder = InputForwarder()
        forwarder.isReady = true
        let view = StreamInputView()
        #expect(forwarder.streamView(view, handleKeyDown: try key(.keyDown, keyCode: kVK_ANSI_W, mods: [.command])) == false)
        forwarder.streamView(view, handleKeyUp: try key(.keyUp, keyCode: kVK_ANSI_W, mods: [.command]))
        #expect(forwarder.heldKeys.isEmpty)
    }
}

/// With ⌘ shortcuts sent to the game, a ⌘ key equivalent goes to the PC only
/// while the stream holds the pointer; otherwise it stays the Mac's.
@MainActor
struct CommandKeyEquivalentTests {

    private func commandTab() throws -> NSEvent {
        try #require(NSEvent.keyEvent(
            with: .keyDown, location: .zero, modifierFlags: [.command], timestamp: 1,
            windowNumber: 0, context: nil, characters: "\t", charactersIgnoringModifiers: "\t",
            isARepeat: false, keyCode: UInt16(kVK_Tab)))
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
}
