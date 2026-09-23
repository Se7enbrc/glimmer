//
//  ShortcutRecordingTests.swift
//
//  The recorder rules: a keyboard shortcut can't be ⇧ alone, a main-menu
//  shortcut, or a copy of another one, and a controller chord needs two buttons.
//

import AppKit
import Testing
@testable import Glimmer

@MainActor
struct ShortcutRecordingTests {

    private let taken: [(name: String, chord: HotkeyChord)] = [
        ("Stop Streaming", .defaultQuit),
        ("Bookmark a Rough Moment", .defaultBookmark),
        ("Paste as Text", PasteText.chord)
    ]

    /// A main menu shaped like the app's: key equivalents in submenus, an
    /// uppercase one that implies ⇧, a second modifier, and a hidden item.
    private let menu: NSMenu = {
        let app = NSMenu(title: "Glimmer"), edit = NSMenu(title: "Edit")
        app.addItem(withTitle: "Quit Glimmer", action: nil, keyEquivalent: "q")
        app.addItem(withTitle: "Hide Others", action: nil, keyEquivalent: "h").keyEquivalentModifierMask = [.command, .option]
        app.addItem(withTitle: "Settings…", action: nil, keyEquivalent: "s")
        edit.addItem(withTitle: "Paste", action: nil, keyEquivalent: "v")
        edit.addItem(withTitle: "Redo", action: nil, keyEquivalent: "Z")
        edit.addItem(withTitle: "Hidden", action: nil, keyEquivalent: "k").isHidden = true
        let main = NSMenu()
        for submenu in [app, edit] {
            main.addItem(withTitle: submenu.title, action: nil, keyEquivalent: "").submenu = submenu
        }
        return main
    }()

    private func problem(_ chord: HotkeyChord) -> String? {
        chord.recordingProblem(taken: taken, menu: menu)
    }

    private func chord(ctrl: Bool = false, alt: Bool = false, shift: Bool = false, cmd: Bool = false,
                       _ key: String) -> HotkeyChord {
        HotkeyChord(ctrl: ctrl, alt: alt, shift: shift, cmd: cmd, keyChar: key)
    }

    @Test func shiftAloneWouldEatCapitalLetters() {
        #expect(problem(chord(shift: true, "w")) != nil)
        #expect(problem(chord(ctrl: true, shift: true, "w")) == nil)
    }

    /// Edit › Paste would take ⌘V before the stream and type the clipboard into
    /// the PC; any main-menu key equivalent is refused by its item's name.
    @Test func theMainMenusShortcutsAreRefused() {
        #expect(problem(chord(cmd: true, "q")) == "Already used for Quit Glimmer.")
        #expect(problem(chord(cmd: true, "v")) == "Already used for Paste.")
        #expect(problem(chord(alt: true, cmd: true, "h")) == "Already used for Hide Others.")
        #expect(problem(chord(shift: true, cmd: true, "z")) == "Already used for Redo.")
        #expect(problem(chord(cmd: true, "s")) == "Already used for Settings.")
    }

    /// Only the exact modifiers match, and a hidden item answers nothing.
    @Test func aNearMissOnTheMenuIsFree() {
        #expect(problem(chord(cmd: true, "h")) == nil)
        #expect(problem(chord(cmd: true, "z")) == nil)
        #expect(problem(chord(ctrl: true, cmd: true, "v")) == nil)
        #expect(problem(chord(cmd: true, "k")) == nil)
    }

    @Test func aCopyNamesTheShortcutThatOwnsIt() {
        #expect(problem(.defaultQuit) == "Already used for Stop Streaming.")
        #expect(problem(chord(ctrl: true, "B")) == "Already used for Bookmark a Rough Moment.")
        #expect(problem(PasteText.chord) == "Already used for Paste as Text.")
    }

    @Test func aFreeChordIsAccepted() {
        #expect(problem(.defaultStats) == nil)
        #expect(problem(chord(ctrl: true, alt: true, "1")) == nil)
    }

    @Test func controllerChordNeedsTwoButtons() {
        #expect(!ChordCaptureSheet.canSave([]))
        #expect(!ChordCaptureSheet.canSave([.r2]))
        #expect(ChordCaptureSheet.canSave([.l3, .r3]))
    }
}
