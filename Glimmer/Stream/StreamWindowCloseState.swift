// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

/// AppKit owns the Space until its transition completes, even if the style bit already changed.
struct StreamWindowCloseState {
    enum Transition: String { case idle, entering, exiting }
    enum Action { case wait, exitSpace, fade, none }

    var transition: Transition = .idle
    private(set) var fadeStarted = false

    mutating func nextAction(isFullScreen: Bool) -> Action {
        guard !fadeStarted else { return .none }
        guard transition == .idle else { return .wait }
        if isFullScreen {
            transition = .exiting
            return .exitSpace
        }
        fadeStarted = true
        return .fade
    }

    /// The watchdog's way out when AppKit never reports the Space settling.
    mutating func forceFade() -> Bool {
        guard !fadeStarted else { return false }
        transition = .idle
        fadeStarted = true
        return true
    }
}
