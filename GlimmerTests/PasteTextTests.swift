//
//  PasteTextTests.swift
//
//  Paste as text: what the clipboard becomes before it is typed into the PC,
//  and the chord that asks for it.
//

import Testing
@testable import Glimmer

struct PasteTextTests {

    @Test func windowsLineEndingsTypeOneNewline() {
        #expect(PasteText.prepared("one\r\ntwo\r\n") == "one\ntwo\n")
        #expect(PasteText.prepared("keep\nthis") == "keep\nthis")
    }

    @Test func passwordsLinksAndAccentsPassUnchanged() {
        let text = "p@ss w\u{F6}rd \u{1F511} https://example.com/?a=1&b=2"
        #expect(PasteText.prepared(text) == text)
    }

    /// A two-byte character that would cross the cap is left out whole.
    @Test func longTextIsCutAtACharacterBoundary() {
        let head = String(repeating: "a", count: PasteText.maxBytes - 1)
        let prepared = PasteText.prepared(head + "\u{E9}tail")
        #expect(prepared == head)
    }

    @Test func chordIsMoonlightsAndCollidesWithNoDefault() {
        let chord = PasteText.chord
        #expect(chord.ctrl && chord.alt && chord.shift && !chord.cmd)
        #expect(chord.keyChar == "v")
        let defaults: [HotkeyChord] = [.defaultQuit, .defaultStats, .defaultBookmark, .defaultReleasePointer, .defaultMiniPlayer]
        #expect(!defaults.contains(chord))
    }
}
