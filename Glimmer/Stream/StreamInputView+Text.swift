// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AppKit

struct StreamTextInput {
    var marked = NSAttributedString(string: "")
    var selection = NSRange(location: 0, length: 0)
    var event: NSEvent?
    var wasComposing = false
    var consumed = false

    static func usesPhysicalKey(text: String, event: NSEvent?, composing: Bool) -> Bool {
        guard !composing, let event, vkScanCode(forCarbonKeyCode: Int(event.keyCode)) != nil else { return false }
        return text == event.characters
    }
}

extension StreamInputView: @MainActor NSTextInputClient {
    /// Shortcuts bypass interpretation; mapped direct characters retain positional input.
    func handleTextInput(_ event: NSEvent) -> Bool {
        guard event.modifierFlags.isDisjoint(with: [.command, .control]) else {
            if hasMarkedText() { cancelComposition() }
            return false
        }
        // The PC repeats physical keys; AppKit repeats would open the accent picker.
        guard !event.isARepeat || hasMarkedText() else { return false }
        textInput.event = event
        textInput.wasComposing = hasMarkedText()
        textInput.consumed = textInput.wasComposing
        defer {
            textInput.event = nil
            textInput.wasComposing = false
        }
        interpretTextEvent(self, event)
        return textInput.consumed || hasMarkedText()
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        let text = Self.inputString(string).string
        let physical = StreamTextInput.usesPhysicalKey(
            text: text, event: textInput.event, composing: textInput.wasComposing || hasMarkedText())
        clearMarkedText()
        guard !physical, !text.isEmpty else { return }
        textInput.consumed = true
        delegate?.streamView(self, commitText: text)
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        let marked = Self.inputString(string)
        textInput.marked = marked
        let location = min(selectedRange.location, marked.length)
        textInput.selection = NSRange(location: location, length: min(selectedRange.length, marked.length - location))
        textInput.consumed = true
    }

    func unmarkText() {
        let text = textInput.marked.string
        clearMarkedText()
        textInput.consumed = true
        delegate?.streamView(self, commitText: text)
    }

    func cancelComposition() {
        clearMarkedText()
        discardMarkedText(self)
    }

    private func clearMarkedText() {
        textInput.marked = NSAttributedString(string: "")
        textInput.selection = NSRange(location: 0, length: 0)
    }

    func hasMarkedText() -> Bool { textInput.marked.length > 0 }
    func markedRange() -> NSRange {
        NSRange(location: hasMarkedText() ? 0 : NSNotFound, length: textInput.marked.length)
    }
    func selectedRange() -> NSRange { textInput.selection }
    func validAttributesForMarkedText() -> [NSAttributedString.Key] { [] }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        guard range.location != NSNotFound, range.location < textInput.marked.length else {
            actualRange?.pointee = NSRange(location: NSNotFound, length: 0)
            return nil
        }
        let available = NSRange(location: range.location, length: min(range.length, textInput.marked.length - range.location))
        actualRange?.pointee = available
        return textInput.marked.attributedSubstring(from: available)
    }

    func characterIndex(for point: NSPoint) -> Int { NSNotFound }

    /// Sunshine supplies no caret geometry, so candidates stay at the picture's lower centre.
    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        actualRange?.pointee = selectedRange()
        let anchor = NSRect(x: bounds.midX, y: bounds.minY + 24, width: 1, height: 20)
        return window?.convertToScreen(convert(anchor, to: nil)) ?? .zero
    }

    private static func inputString(_ value: Any) -> NSAttributedString {
        if let attributed = value as? NSAttributedString { return attributed }
        return NSAttributedString(string: value as? String ?? "")
    }
}
