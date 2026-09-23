//
//  InputForwarder+Paste.swift
//
//  Paste as text (moonlight's ⌃⌥⇧V): the Mac clipboard is typed into the PC
//  as characters, so passwords, links, codes and accented text arrive as
//  written whatever the PC's keyboard layout. Keys are otherwise positional.
//

import AppKit

/// The text rules, pure so they are testable without a pasteboard or a stream.
enum PasteText {
    /// moonlight's chord, for when ⌘V goes to the game.
    static let chord = HotkeyChord(ctrl: true, alt: true, shift: true, cmd: false, keyChar: "v")

    /// Plenty for a password, a code or a link; a clipboard of prose is cut.
    static let maxBytes = 4096

    /// Windows line endings become one newline (each would otherwise type two
    /// Enters), and the text is cut at a character boundary within the cap.
    static func prepared(_ text: String) -> String {
        var out = ""
        var bytes = 0
        for character in text.replacingOccurrences(of: "\r\n", with: "\n") {
            bytes += character.utf8.count
            guard bytes <= maxBytes else { break }
            out.append(character)
        }
        return out
    }
}

extension InputForwarder {

    func streamViewPaste(_ view: StreamInputView) {
        pasteClipboardAsText()
    }

    /// Held input is released first so a held modifier cannot turn the text
    /// into shortcuts, and the text waits one beat for those releases, which
    /// ride another channel. Reading the clipboard here is a user paste.
    func pasteClipboardAsText() {
        guard isReady, let clipboard = NSPasteboard.general.string(forType: .string) else { return }
        let text = PasteText.prepared(clipboard)
        guard !text.isEmpty else { return }
        raiseAllHeldInputs(reason: "paste")
        // Modifiers still down (the chord's own) are up on the PC now: count them
        // as held, so letting go sends a harmless release instead of a press.
        heldModifierVKs = ModifierSides.held(in: NSEvent.modifierFlags, includeCommand: captureSysKeys)
        log.info("Pasting \(text.utf8.count, privacy: .public) bytes as text")
        Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(50))
            guard let self, self.isReady else { return }
            self.record("LiSendUtf8TextEvent", self.backend?.sendUtf8Text(text) ?? -2)
        }
    }
}
