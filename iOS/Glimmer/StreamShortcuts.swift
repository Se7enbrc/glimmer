// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import Observation
import UIKit

@MainActor
@Observable
final class StreamShortcuts {
    enum Action: String, CaseIterable {
        case quit, stats
        var title: String { self == .quit ? "Stop Streaming" : "Show or Hide Stream Stats" }
        var key: String { self == .quit ? "quitHotkey" : "statsHotkey" }
    }

    private let defaults: UserDefaults
    var quit: HotkeyChord { didSet { save(quit, key: Action.quit.key) } }
    var stats: HotkeyChord { didSet { stats.persistStats(defaults: defaults) } }
    private var held: Set<String> = []
    private var physicalKeys: [UInt16: (input: String, local: Bool)] = [:]

    init(defaults: UserDefaults = PersistentStorage.defaults) {
        self.defaults = defaults
        quit = defaults.data(forKey: Action.quit.key)
            .flatMap { try? JSONDecoder().decode(HotkeyChord.self, from: $0) } ?? .defaultQuit
        stats = HotkeyChord.persistedStats(defaults: defaults)
    }

    func chord(for action: Action) -> HotkeyChord { action == .quit ? quit : stats }

    func set(_ chord: HotkeyChord, for action: Action) {
        if action == .quit { quit = chord } else { stats = chord }
    }

    func match(input: String, modifiers: UIKeyModifierFlags) -> Action? {
        guard !(UIAccessibility.isVoiceOverRunning && modifiers.isSuperset(of: [.control, .alternate])) else {
            return nil
        }
        return Action.allCases.first {
            let chord = chord(for: $0)
            return !chord.keyChar.isEmpty && chord.keyChar.lowercased() == input.lowercased()
                && chord.modifiers == modifiers.intersection([.control, .alternate, .shift, .command])
        }
    }

    /// Both responder entry points own the whole chord until release, including repeats.
    @discardableResult
    func handle(input: String, modifiers: UIKeyModifierFlags, perform: (Action) -> Void) -> Bool {
        let key = input.lowercased()
        guard !physicalKeys.values.contains(where: { !$0.local && $0.input == key }) else { return false }
        if held.contains(key) { return true }
        guard let action = match(input: input, modifiers: modifiers) else { return false }
        held.insert(key)
        perform(action)
        return true
    }

    @discardableResult
    func release(input: String) -> Bool { held.remove(input.lowercased()) != nil }

    func reset() {
        held.removeAll()
        physicalKeys.removeAll()
    }

    /// UIKit resolves the current layout; physical ownership then lasts until that key is released.
    @discardableResult
    func routeKey(usage: UInt16, input: String, modifiers: UIKeyModifierFlags, pressed: Bool,
                  forward: (Bool) -> Bool, perform: (Action) -> Void, showControls: () -> Void) -> Bool {
        let previous = physicalKeys[usage]
        let controls = input == "/" && modifiers == .control
        let local = previous?.local ?? (controls || match(input: input, modifiers: modifiers) != nil)
        let owned = forward(local)
        if pressed {
            if previous == nil { physicalKeys[usage] = (input.lowercased(), owned) }
            if owned {
                if controls {
                    if previous == nil { showControls() }
                } else { handle(input: previous?.input ?? input, modifiers: modifiers, perform: perform) }
            }
        } else {
            let original = physicalKeys.removeValue(forKey: usage)?.input ?? input
            release(input: original)
        }
        return owned
    }

    private func save(_ chord: HotkeyChord, key: String) {
        guard let data = try? JSONEncoder().encode(chord) else { return }
        defaults.set(data, forKey: key)
    }
}

extension HotkeyChord {
    var modifiers: UIKeyModifierFlags {
        var flags: UIKeyModifierFlags = []
        if ctrl { flags.insert(.control) }
        if alt { flags.insert(.alternate) }
        if shift { flags.insert(.shift) }
        if cmd { flags.insert(.command) }
        return flags
    }

    @MainActor init?(key: UIKey) {
        let input = key.charactersIgnoringModifiers.lowercased()
        guard input.count == 1, let character = input.first,
              character.isLetter || character.isNumber else { return nil }
        let flags = key.modifierFlags
        guard !flags.isDisjoint(with: [.control, .alternate, .shift, .command]) else { return nil }
        self.init(ctrl: flags.contains(.control), alt: flags.contains(.alternate), shift: flags.contains(.shift),
                  cmd: flags.contains(.command), keyChar: input)
    }
}
