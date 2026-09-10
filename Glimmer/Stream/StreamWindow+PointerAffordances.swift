//
//  StreamWindow+PointerAffordances.swift
//
//  The one thing that makes window-mode pointer capture teachable: a transient
//  hint on the first few grabs saying how to give the pointer back.
//
//  It carries more weight than it used to. The pointer is now grabbed by being
//  over the window - no button, no click - so there is no visible control left
//  to explain the bargain, and this pill is the only place the user is ever
//  told that a held Esc is the way out. Hence a budget of three shows rather
//  than one: once is easy to miss when a game takes your attention the instant
//  the cursor disappears.
//
//  Window mode only. A fullscreen cover captures for the whole session, so
//  there is nothing to hint about; every entry point here is gated on
//  `displayMode == .window` and the fullscreen path never reaches them.
//

import AppKit

// MARK: - Hint budget

/// How many times the capture hint is worth showing. Pure so the rule is
/// testable without UserDefaults, and separate from the storage so the caller
/// owns the read/write.
enum CaptureHintPolicy {
    /// UserDefaults key holding the number of window captures that have shown
    /// the hint. An Int (not a Bool) because the hint earns a few repeats:
    /// once is easy to miss when a game grabs your attention the instant the
    /// pointer is captured.
    static let defaultsKey = "windowCaptureHintCount"

    /// After this many, the user knows. Teaching aids that never stop are
    /// nagging.
    static let maxShows = 3

    static func shouldShow(count: Int) -> Bool { count < maxShows }

    /// The count to persist after a show. Clamps a negative value (a hand-
    /// edited or corrupt default) up to zero first, so a nonsense count
    /// self-heals into the normal budget instead of showing forever.
    static func nextCount(after count: Int) -> Int { max(count, 0) + 1 }
}

// MARK: - StreamWindow

extension StreamWindow {

    /// The first few captures explain the way out. Uses the same pill the
    /// one-time leave hint uses, so the two teaching toasts look like one
    /// idea, and stacks above it so they can never overlap.
    ///
    /// The budget is persisted, not session-scoped: the lesson only needs
    /// teaching once per person, not once per launch.
    func showCaptureHintIfBudgetAllows() {
        let defaults = UserDefaults.standard
        let count = defaults.integer(forKey: CaptureHintPolicy.defaultsKey)
        guard CaptureHintPolicy.shouldShow(count: count) else { return }
        defaults.set(CaptureHintPolicy.nextCount(after: count), forKey: CaptureHintPolicy.defaultsKey)

        captureHintBanner.setText("Hold Esc to free the pointer")
        captureHintBanner.setVisible(true)
        // ~4s all in: 0.2s fade in, 3.6s legible, 0.2s fade out. The
        // generation stamp means a re-capture inside that window re-shows the
        // hint without the first show's timer cutting the second one short.
        captureHintGeneration &+= 1
        let generation = captureHintGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.6) { [weak self] in
            guard let self, self.captureHintGeneration == generation else { return }
            self.captureHintBanner.setVisible(false)
        }
    }

    /// Drop the hint the moment the pointer comes back - it is advice about
    /// being captured, and it would read as a lie hanging over a free pointer.
    func hideCaptureHint() {
        captureHintGeneration &+= 1
        captureHintBanner.setVisible(false)
    }
}
