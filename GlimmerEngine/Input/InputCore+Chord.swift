// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

extension InputCore {
    package func updateChord(slot: UInt8, held: Bool, invalidate: Bool = false) {
        withLock {
            guard invalidate || chordSlots.contains(slot) != held else { return }
            if held { chordSlots.insert(slot) } else { chordSlots.remove(slot) }
            let edge = UUID()
            chordEdges[slot] = edge
            onChord?(slot, held, edge)
        }
    }

    package func clearChords() {
        withLock {
            for slot in chordSlots { updateChord(slot: slot, held: false, invalidate: true) }
        }
    }
}
