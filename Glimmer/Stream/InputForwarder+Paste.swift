// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Text commits preserve held game input; clipboard pastes release it first.

import GlimmerEngine
import AppKit

/// The text rules, pure so they are testable without a pasteboard or a stream.
enum PasteText {
    /// Two keys like every other in-stream chord, for when ⌘V goes to the game.
    static let chord = HotkeyChord(ctrl: true, alt: false, shift: false, cmd: false, keyChar: "v")

    static let maxBytes = InputText.maxBytes
    static func prepared(_ text: String) -> String { InputText.prepared(text) }
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
        guard isReady, backend != nil, !text.isEmpty else { return nil }
        if deferKeyboardEvent({ $0.queueText(text, modifiers: modifiers, waitForRelease: waitForRelease) }) {
            return pendingTextTask
        }
        let needsDelay = waitForRelease || !heldModifierVKs.isEmpty
        for vk in heldModifierVKs.sorted() { sendModifier(vk, down: false, modByte: 0) }
        // Retain native held modifiers so their eventual release cannot become a new press.
        heldModifierVKs = ModifierSides.held(in: modifiers, includeCommand: forwardsCommand)
        modifiersNeedResync = false
        let generation = inputGeneration
        let task = InputText.send(text, core: inputCore, waitForRelease: needsDelay,
            isCurrent: { [weak self] in self?.isReady == true && self?.inputGeneration == generation },
            flushReleases: { [weak self] in self?.flushPendingReleases() ?? false }, finished: { [weak self] in
                guard let self else { return }
                self.pendingTextTask = nil
                let queued = self.pendingKeyboardEvents
                self.pendingKeyboardEvents.removeAll()
                for event in queued { event(self) }
                await self.pendingTextTask?.value
            })
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
