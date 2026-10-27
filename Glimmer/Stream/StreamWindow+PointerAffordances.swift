// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

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

import GlimmerEngine
import AppKit

// MARK: - Hint budget

/// How many times a teaching hint is worth showing, persisted per hint. The
/// count rule is pure so it is testable without UserDefaults.
struct HintBudget {
    /// UserDefaults key holding how many times this hint has shown. An Int
    /// (not a Bool) because a hint earns a few repeats: once is easy to miss
    /// when a game grabs your attention the instant it appears.
    let defaultsKey: String

    static let windowCapture = HintBudget(defaultsKey: "windowCaptureHintCount")
    static let leaveStream = HintBudget(defaultsKey: "glimmer.leaveHintCount")

    /// After this many, the user knows. Teaching aids that never stop are
    /// nagging.
    static let maxShows = 3

    static func shouldShow(count: Int) -> Bool { count < maxShows }

    /// The count to persist after a show. Clamps a negative value (a hand-
    /// edited or corrupt default) up to zero first, so a nonsense count
    /// self-heals into the normal budget instead of showing forever.
    static func nextCount(after count: Int) -> Int { max(count, 0) + 1 }

    /// Spend one show from the persisted count; false once the budget is gone.
    func claimShow(in defaults: UserDefaults = PersistentStorage.defaults) -> Bool {
        let count = defaults.integer(forKey: defaultsKey)
        guard Self.shouldShow(count: count) else { return false }
        defaults.set(Self.nextCount(after: count), forKey: defaultsKey)
        return true
    }
}

// MARK: - StreamWindow

extension StreamWindow {

    /// The first few captures explain the way out, in the leave hint's pill and
    /// stacked above it. The budget is persisted: the lesson needs teaching
    /// once per person, not once per launch.
    func showCaptureHintIfBudgetAllows() {
        guard HintBudget.windowCapture.claimShow() else { return }
        showPointerHint("Hold Esc to free the pointer")
    }

    func showPointerModeHint(captured: Bool) {
        showPointerHint(captured ? "Pointer captured" : "Pointer follows the picture")
    }

    private func showPointerHint(_ text: String) {
        captureHintBanner.setText(text)
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

    // The mode pill speaks for 2 s, then a silent glyph stays in a clear corner until the mode ends.
    func showControllerMouseMode(_ message: String, enabled: Bool) {
        showStreamToast(message, for: 2, symbol: ControllerMouseMapping.modeSymbol(enabled: enabled))
        mouseModeBadgeGeneration &+= 1
        guard enabled else { mouseModeBadge.setVisible(false); return }
        let generation = mouseModeBadgeGeneration
        scheduleMouseModeBadge(2) { [weak self] in
            guard let self, self.mouseModeBadgeGeneration == generation else { return }
            self.mouseModeBadge.setVisible(true)
        }
    }

    func configureMouseModeBadge() {
        let badge = mouseModeBadge
        badge.setSymbol(ControllerMouseMapping.modeSymbol(enabled: true))
        badge.accessibilityName = "Mouse mode on"
        badge.announce = { _ in }
        badge.avoiding = { [weak self] in self?.mouseModeBadgeObstacles() ?? [] }
        for notice in [reconnectBanner, networkBanner, leaveHintBanner, captureHintBanner] {
            notice.presenceChanged = { [weak badge] in badge?.relayout() }
        }
    }

    /// The stats panel (shown or not) and visible notices, in top-left-origin content coordinates.
    func mouseModeBadgeObstacles() -> [CGRect] {
        let height = displayView.bounds.height
        let flip = { (rect: CGRect) in CGRect(x: rect.minX, y: height - rect.maxY, width: rect.width, height: rect.height) }
        let stats = statsOverlay.layer.frame.isEmpty
            ? StatsOverlayLayer.panelFrame(size: CGSize(width: 260, height: 180), in: displayView.bounds,
                                           corner: statsOverlay.corner)
            : statsOverlay.layer.frame
        let notices = [reconnectBanner, networkBanner, leaveHintBanner, captureHintBanner].compactMap(\.noticeFrame)
        return [flip(stats)] + notices.map(flip)
    }

    // Mode changes replace the teaching toast so transient messages occupy one place.
    func showStreamToast(_ text: String, for duration: TimeInterval, symbol: String? = nil) {
        leaveHintBanner.setSymbol(symbol)
        leaveHintBanner.setText(text)
        leaveHintBanner.setVisible(true)
        streamToastGeneration &+= 1
        let generation = streamToastGeneration
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) { [weak self] in
            guard let self, self.streamToastGeneration == generation else { return }
            self.leaveHintBanner.setVisible(false)
        }
    }
}
