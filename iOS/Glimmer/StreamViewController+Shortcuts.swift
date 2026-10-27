// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import UIKit

extension StreamViewController {
    override var canBecomeFirstResponder: Bool { true }

    override var keyCommands: [UIKeyCommand]? {
        guard model.canStart, !model.phase.isEnded, model.phase != .stopping else { return [] }
        return StreamShortcuts.Action.allCases.compactMap { action in
            let chord = model.shortcuts.chord(for: action)
            guard !chord.keyChar.isEmpty else { return nil }
            let command = UIKeyCommand(title: action.title, action: #selector(streamShortcut),
                                       input: chord.keyChar, modifierFlags: chord.modifiers)
            command.wantsPriorityOverSystemBehavior = true
            return command
        }
    }

    @objc private func streamShortcut(_ command: UIKeyCommand) {
        guard let input = command.input else { return }
        model.shortcuts.handle(input: input, modifiers: command.modifierFlags, perform: model.performShortcut)
    }

    override func pressesBegan(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = presses.filter { press in
            guard let key = press.key else { return true }
            return !model.shortcuts.handle(input: key.charactersIgnoringModifiers, modifiers: key.modifierFlags,
                                           perform: model.performShortcut)
        }
        if !remaining.isEmpty { super.pressesBegan(remaining, with: event) }
    }

    override func pressesEnded(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        let remaining = presses.filter { press in
            guard let key = press.key else { return true }
            return !model.shortcuts.release(input: key.charactersIgnoringModifiers)
        }
        if !remaining.isEmpty { super.pressesEnded(remaining, with: event) }
    }

    override func pressesCancelled(_ presses: Set<UIPress>, with event: UIPressesEvent?) {
        model.shortcuts.reset()
        super.pressesCancelled(presses, with: event)
    }
}
