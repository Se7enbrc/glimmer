// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import GlimmerEngine
import Synchronization

/// Hardware callbacks and native layout decisions share this gate without task handoffs.
final class IOSHardwareInput: Sendable {
    private enum KeyOwner { case local, hardware, native }

    private struct State {
        var active = false
        var generation: UInt64 = 0
        var gameKeys: Set<UInt16> = []
        var unresolvedKeys: Set<UInt16> = []
        var nativeKeys: [UInt16: KeyOwner] = [:]
    }
    private let state = Mutex(State())
    private let input: StreamInput
    private let shortcutModifiers: Set<UInt8>

    init(input: StreamInput, quit: HotkeyChord, stats: HotkeyChord) {
        self.input = input
        var modifiers: Set<UInt8> = [2]
        for chord in [quit, stats] where !chord.keyChar.isEmpty {
            modifiers.insert((chord.shift ? 1 : 0) | (chord.ctrl ? 2 : 0)
                | (chord.alt ? 4 : 0) | (chord.cmd ? 8 : 0))
        }
        shortcutModifiers = modifiers
    }

    @discardableResult
    func focus(_ active: Bool) -> UInt64 {
        state.withLock {
            $0.generation &+= 1
            $0.active = active
            $0.gameKeys.removeAll(keepingCapacity: true)
            $0.unresolvedKeys.removeAll(keepingCapacity: true)
            $0.nativeKeys.removeAll(keepingCapacity: true)
            if !active { input.releaseKeyboardAndPointer() }
            return $0.generation
        }
    }

    @discardableResult
    func key(_ usage: UInt16, pressed: Bool, modifiers: UInt8, at time: TimeInterval,
             generation: UInt64, local nativeLocal: Bool? = nil) -> Bool {
        state.withLock {
            guard $0.active, $0.generation == generation else { return false }
            if let nativeLocal {
                return nativeKey(usage, pressed: pressed, modifiers: modifiers, at: time,
                                 local: nativeLocal, state: &$0)
            }
            if $0.unresolvedKeys.contains(usage) {
                if !pressed { $0.unresolvedKeys.remove(usage) }
                return false
            }
            if pressed, !$0.gameKeys.contains(usage), needsLayout(usage, modifiers: modifiers) {
                // UIKit resolves possible chords; ordinary gameplay stays on the hardware callback.
                $0.unresolvedKeys.insert(usage)
                return false
            }
            if pressed { $0.gameKeys.insert(usage) } else { $0.gameKeys.remove(usage) }
            input.setKey(hidUsage: usage, pressed: pressed, modifiers: modifiers, capturedAt: time)
            return false
        }
    }

    private func needsLayout(_ usage: UInt16, modifiers: UInt8) -> Bool {
        !(224...231).contains(usage) && shortcutModifiers.contains(modifiers)
    }

    private func nativeKey(_ usage: UInt16, pressed: Bool, modifiers: UInt8, at time: TimeInterval,
                           local: Bool, state: inout State) -> Bool {
        if pressed, state.nativeKeys[usage] == nil {
            let hardware = !needsLayout(usage, modifiers: modifiers)
            state.nativeKeys[usage] = hardware ? .hardware : (local ? .local : .native)
        }
        guard let owner = state.nativeKeys[usage] else { return false }
        if !pressed { state.nativeKeys.removeValue(forKey: usage) }
        // Each press has exactly one sender, even when an entire callback sequence arrives late.
        if owner == .native {
            input.setKey(hidUsage: usage, pressed: pressed, modifiers: modifiers, capturedAt: time)
        }
        return owner == .local
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
