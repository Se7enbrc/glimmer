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
