// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import GlimmerEngine
import Synchronization

/// Capture callbacks and focus changes share this gate; no gameplay event crosses the main actor.
final class IOSHardwareInput: Sendable {
    struct Shortcut: Sendable {
        let usage: UInt16?
        let modifiers: UInt8

        init(_ chord: HotkeyChord) {
            let character = chord.keyChar.lowercased().utf8.first
            usage = character.flatMap { value in
                if (97...122).contains(value) { return UInt16(value - 97 + 4) }
                if (49...57).contains(value) { return UInt16(value - 49 + 30) }
                return value == 48 ? 39 : nil
            }
            modifiers = (chord.shift ? 1 : 0) | (chord.ctrl ? 2 : 0)
                | (chord.alt ? 4 : 0) | (chord.cmd ? 8 : 0)
        }
    }

    private struct State {
        var active = false
        var generation: UInt64 = 0
        var localKeys: Set<UInt16> = []
    }
    private let state = Mutex(State())
    private let input: StreamInput
    private let quit: Shortcut
    private let stats: Shortcut

    init(input: StreamInput, quit: HotkeyChord, stats: HotkeyChord) {
        self.input = input
        self.quit = Shortcut(quit)
        self.stats = Shortcut(stats)
    }

    @discardableResult
    func focus(_ active: Bool) -> UInt64 {
        state.withLock {
            $0.generation &+= 1
            $0.active = active
            $0.localKeys.removeAll(keepingCapacity: true)
            if !active { input.releaseKeyboardAndPointer() }
            return $0.generation
        }
    }

    func key(_ usage: UInt16, pressed: Bool, modifiers: UInt8, at time: TimeInterval, generation: UInt64) {
        state.withLock {
            guard $0.active, $0.generation == generation else { return }
            if $0.localKeys.contains(usage) {
                if !pressed { $0.localKeys.remove(usage) }
                return
            }
            let local = (usage == 56 && modifiers == 2)
                || (usage == quit.usage && modifiers == quit.modifiers)
                || (usage == stats.usage && modifiers == stats.modifiers)
            if local {
                if pressed { $0.localKeys.insert(usage) }
                return
            }
            input.setKey(hidUsage: usage, pressed: pressed, modifiers: modifiers, capturedAt: time)
        }
    }

    func move(x: Double, y: Double, at time: TimeInterval, generation: UInt64) {
        state.withLock {
            guard $0.active, $0.generation == generation else { return }
            input.movePointer(dx: x, dy: -y, capturedAt: time)
        }
    }

    func button(_ button: PointerButton, pressed: Bool, at time: TimeInterval, generation: UInt64) {
        state.withLock {
            guard $0.active, $0.generation == generation else { return }
            input.setPointerButton(button, pressed: pressed, capturedAt: time)
        }
    }

    func scroll(x: Double, y: Double, at time: TimeInterval, generation: UInt64) {
        state.withLock {
            guard $0.active, $0.generation == generation else { return }
            input.scroll(x: x, y: y, precise: false, capturedAt: time)
        }
    }
}
