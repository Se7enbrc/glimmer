// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

extension StreamInput {
    /// Existing stop-chord presets. Matching remains local and requests disconnect, never PC game termination.
    public enum StopChord: Sendable {
        case none, menuOptionsShoulders, shoulders, shouldersAndTriggers, stickButtons

        var coreValue: ControllerQuitChord {
            switch self {
            case .none: .none
            case .menuOptionsShoulders: .startSelectL1R1
            case .shoulders: .l1r1
            case .shouldersAndTriggers: .l1r1l2r2
            case .stickButtons: .l3r3
            }
        }
    }

    public func setStopChord(_ chord: StopChord) {
        core.withLock {
            guard !terminal else { return }
            core.snapshot.chord = chord.coreValue
            invalidateChordContext()
        }
    }

    func invalidateChordContext() {
        chordContext = UUID()
        Task { @MainActor [weak self] in
            guard let self else { return }
            self.chordDwell.synchronize(context: self.core.withLock { self.chordContext })
        }
    }

    func chordChanged(slot: UInt8, held: Bool, edge: UUID) {
        guard let identity = registrations[slot]?.identity else { return }
        let context = chordContext
        Task { @MainActor [weak self] in
            guard let self else { return }
            let valid = self.core.withLock {
                !self.terminal && self.chordContext == context && self.core.chordEdges[slot] == edge
                    && (self.registrations[slot]?.identity == identity || (!held && self.registrations[slot] == nil))
                    && self.core.chordSlots.contains(slot) == held
            }
            guard valid else { return }
            self.chordDwell.synchronize(context: context)
            guard held else { self.chordDwell.cancel(slot: slot); return }
            self.chordDwell.arm(slot: slot, edge: edge, held: { [weak self] in
                guard let self else { return false }
                return self.core.withLock {
                    !self.terminal && self.core.snapshot.ready && self.core.snapshot.focused
                        && self.chordContext == context && self.core.chordEdges[slot] == edge
                        && self.registrations[slot]?.identity == identity && self.core.chordSlots.contains(slot)
                }
            }, expired: { [weak self] held in
                if held { self?.emit(.stopRequested) }
            })
        }
    }
}
