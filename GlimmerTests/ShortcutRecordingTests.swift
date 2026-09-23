//
//  ShortcutRecordingTests.swift
//
//  The recorder rules: a keyboard shortcut can't be ⇧ alone, a Mac ⌘ shortcut,
//  or a copy of another one, and a controller chord needs two buttons.
//

import Testing
@testable import Glimmer

struct ShortcutRecordingTests {

    private let taken: [(name: String, chord: HotkeyChord)] = [
        ("Stop Streaming", .defaultQuit),
        ("Bookmark a rough moment", .defaultBookmark),
        ("Paste as text", PasteText.chord)
    ]

    private func chord(ctrl: Bool = false, alt: Bool = false, shift: Bool = false, cmd: Bool = false,
                       _ key: String) -> HotkeyChord {
        HotkeyChord(ctrl: ctrl, alt: alt, shift: shift, cmd: cmd, keyChar: key)
    }

    @Test func shiftAloneWouldEatCapitalLetters() {
        #expect(chord(shift: true, "w").recordingProblem(taken: taken) != nil)
        #expect(chord(ctrl: true, shift: true, "w").recordingProblem(taken: taken) == nil)
    }

    @Test func theMacsCommandShortcutsAreRefused() {
        for key in ["q", "w", "h", "m"] {
            #expect(chord(cmd: true, key).recordingProblem(taken: taken) == "This Mac already uses ⌘\(key.uppercased()).")
        }
        #expect(chord(alt: true, cmd: true, "w").recordingProblem(taken: taken) != nil)
        #expect(chord(cmd: true, "k").recordingProblem(taken: taken) == nil)
    }

    @Test func aCopyNamesTheShortcutThatOwnsIt() {
        #expect(HotkeyChord.defaultQuit.recordingProblem(taken: taken) == "Already used for Stop Streaming.")
        #expect(chord(ctrl: true, "B").recordingProblem(taken: taken) == "Already used for Bookmark a rough moment.")
        #expect(PasteText.chord.recordingProblem(taken: taken) == "Already used for Paste as text.")
    }

    @Test func aFreeChordIsAccepted() {
        #expect(HotkeyChord.defaultStats.recordingProblem(taken: taken) == nil)
        #expect(chord(ctrl: true, alt: true, "1").recordingProblem(taken: taken) == nil)
    }

    @Test func controllerChordNeedsTwoButtons() {
        #expect(!ChordCaptureSheet.canSave([]))
        #expect(!ChordCaptureSheet.canSave([.r2]))
        #expect(ChordCaptureSheet.canSave([.l3, .r3]))
    }
}
