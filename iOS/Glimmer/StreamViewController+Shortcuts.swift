// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import UIKit

extension StreamViewController {
    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        guard model.canStart, !model.phase.isEnded, model.phase != .stopping else { return [] }
        let controls = UIKeyCommand(title: "Show controls", action: #selector(showStreamControls),
                                    input: "/", modifierFlags: .control)
        controls.wantsPriorityOverSystemBehavior = true
        return [controls] + StreamShortcuts.Action.allCases.compactMap { action in
            let chord = model.shortcuts.chord(for: action)
            guard !chord.keyChar.isEmpty else { return nil }
            let command = UIKeyCommand(title: action.title, action: #selector(streamShortcut),
                                       input: chord.keyChar, modifierFlags: chord.modifiers)
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    @objc func showStreamControls() { model.showControls() }

    @objc private func streamShortcut(_ command: UIKeyCommand) {
        guard let input = command.input else { return }
        model.shortcuts.handle(input: input, modifiers: command.modifierFlags, perform: model.performShortcut)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = presses.filter { press in
            guard let key = press.key else { return true }
            if model.inputFocused, let capture = keyboardMouseCapture {
                routeKey(key, pressed: true, capture: capture)
                return false
            }
            if key.charactersIgnoringModifiers == "/", key.modifierFlags == .control {
                model.showControls()
                return false
            }
            if model.shortcuts.handle(input: key.charactersIgnoringModifiers, modifiers: key.modifierFlags,
                                      perform: model.performShortcut) { return false }
            return !model.inputFocused
        }
        if !remaining.isEmpty { super.pressesBegan(remaining, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = presses.filter { press in
            guard let key = press.key else { return true }
            if let capture = keyboardMouseCapture {
                routeKey(key, pressed: false, capture: capture)
                return !model.inputFocused
            }
            if key.charactersIgnoringModifiers == "/", key.modifierFlags == .control { return false }
            return !model.shortcuts.release(input: key.charactersIgnoringModifiers) && !model.inputFocused
        }
        if !remaining.isEmpty { super.pressesEnded(remaining, with: event) }
    }

    private func routeKey(_ key: UIKey, pressed: Bool, capture: IOSKeyboardMouseCapture) {
        model.shortcuts.routeKey(usage: UInt16(clamping: key.keyCode.rawValue),
            input: key.charactersIgnoringModifiers, modifiers: key.modifierFlags, pressed: pressed,
            forward: { capture.key(key, pressed: pressed, local: $0) },
            perform: model.performShortcut, showControls: model.showControls)
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        model.shortcuts.reset()
        model.streamInput?.releaseKeyboardAndPointer()
        super.pressesCancelled(presses, with: event)
    }
}
