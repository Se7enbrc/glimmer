// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import UIKit

@MainActor
enum StreamDisplayMode {
    struct State {
        let mode: UIScreenMode?
        let overscan: UIScreen.OverscanCompensation
    }

    static func prepare(_ window: UIWindow) -> (@MainActor () -> Void) {
        guard let screen = window.windowScene?.screen else { return {} }
        return prepare(preferredMode: screen.preferredMode, read: {
            State(mode: screen.currentMode, overscan: screen.overscanCompensation)
        }, write: { state in
            screen.currentMode = state.mode
            screen.overscanCompensation = state.overscan
        })
    }

    static func prepare(preferredMode: UIScreenMode?, read: @escaping @MainActor () -> State,
                        write: @escaping @MainActor (State) -> Void) -> (@MainActor () -> Void) {
        let original = read()
        write(State(mode: preferredMode ?? original.mode, overscan: .scale))
        let applied = read()
        var restored = false
        return {
            guard !restored else { return }
            restored = true
            let current = read()
            // Do not overwrite a mode changed by the system or the player while streaming.
            write(State(mode: current.mode === applied.mode ? original.mode : current.mode,
                        overscan: current.overscan == applied.overscan ? original.overscan : current.overscan))
        }
    }
}
