// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Text commits preserve held game input; clipboard pastes release it first.

import AppKit

/// The text rules, pure so they are testable without a pasteboard or a stream.
enum PasteText {
    /// Two keys like every other in-stream chord, for when ⌘V goes to the game.
    static let chord = HotkeyChord(ctrl: true, alt: false, shift: false, cmd: false, keyChar: "v")

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

    func streamView(_ view: StreamInputView, commitText text: String) {
        guard isReady, !isMouseCaptured, !text.isEmpty, window?.isKeyWindow != false,
              window?.ignoresMouseEvents != true else { return }
        queueText(text)
    }

    func streamViewPaste(_ view: StreamInputView) {
        pasteClipboardAsText()
    }

    /// Held input is released first so a held modifier cannot turn the text
    /// into shortcuts, and the text waits one beat for those releases, which
    /// ride another channel. Reading the clipboard here is a user paste.
    @discardableResult
    func pasteClipboardAsText(read: () -> String? = { NSPasteboard.general.string(forType: .string) })
        -> Task<Void, Never>? {
        guard isReady, let clipboard = read() else { return nil }
        return queuePasteText(clipboard)
    }

    @discardableResult
    func queuePasteText(_ clipboard: String) -> Task<Void, Never>? {
        guard isReady, backend != nil else { return nil }
        let text = PasteText.prepared(clipboard)
        guard !text.isEmpty else { return nil }
        if deferKeyboardEvent({ $0.queuePasteText(clipboard) }) { return pendingTextTask }
        raiseAllHeldInputs(reason: "paste")
        log.info("Pasting \(text.utf8.count, privacy: .public) bytes as text")
        return queueText(text, waitForRelease: true)
    }

    @discardableResult
    func queueText(_ text: String, modifiers: NSEvent.ModifierFlags = NSEvent.modifierFlags,
                   waitForRelease: Bool = false) -> Task<Void, Never>? {
        inputCore.lock.lock(); defer { inputCore.lock.unlock() }
        guard isReady, let backend, !text.isEmpty else { return nil }
        if deferKeyboardEvent({ $0.queueText(text, modifiers: modifiers, waitForRelease: waitForRelease) }) {
            return pendingTextTask
        }
        let needsDelay = waitForRelease || !heldModifierVKs.isEmpty
        for vk in heldModifierVKs.sorted() { sendModifier(vk, down: false, modByte: 0) }
        // Modifiers still down (the chord's own) are up on the PC now: count them
        // as held, so letting go sends a harmless release instead of a press.
        heldModifierVKs = ModifierSides.held(in: modifiers, includeCommand: forwardsCommand)
        modifiersNeedResync = false
        if !needsDelay, flushPendingReleases() {
            record("LiSendUtf8TextEvent", backend.sendUtf8Text(text))
            return nil
        }
        let generation = inputGeneration
        let deadline = ContinuousClock.now.advanced(by: .milliseconds(50))
        let task = Task { [weak self] in
            try? await Task.sleep(until: deadline, clock: .continuous)
            guard let self else { return }
            while !Task.isCancelled, self.isReady, self.inputGeneration == generation {
                let sent = self.inputCore.withLock {
                    guard self.flushPendingReleases() else { return false }
                    self.record("LiSendUtf8TextEvent", backend.sendUtf8Text(text))
                    return true
                }
                if sent { break }
                do { try await Task.sleep(for: .milliseconds(50)) } catch { break }
            }
            self.pendingTextTask = nil
            let queued = self.pendingKeyboardEvents
            self.pendingKeyboardEvents.removeAll()
            for event in queued { event(self) }
            await self.pendingTextTask?.value
        }
        pendingTextTask = task
        return task
    }

    /// Replay through the same handlers so a later composition can start its own release wait.
    func deferKeyboardEvent(_ event: @escaping (InputForwarder) -> Void) -> Bool {
        guard pendingTextTask != nil else { return false }
        let generation = inputGeneration
        pendingKeyboardEvents.append { forwarder in
            guard forwarder.isReady, forwarder.inputGeneration == generation else { return }
            event(forwarder)
        }
        return true
    }
}
