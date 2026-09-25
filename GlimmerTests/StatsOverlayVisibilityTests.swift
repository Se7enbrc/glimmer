//
//  StatsOverlayVisibilityTests.swift
//
//  Covers the overlay's show/hide de-dup (#88): a hide defers `layer.isHidden`
//  to a CATransaction completion, so the de-dup must key off intent, not the
//  lagging layer state. `showRightAfterHideWins` is the stream-start sequence.
//

import QuartzCore
import Testing
@testable import Glimmer

@MainActor
struct StatsOverlayVisibilityTests {

    @Test func batteryCacheExpiresAfterTenSeconds() {
        #expect(MacSystemStats.batteryCacheIsStale(sampledAt: nil, now: 0))
        #expect(!MacSystemStats.batteryCacheIsStale(sampledAt: 5, now: 14.999))
        #expect(MacSystemStats.batteryCacheIsStale(sampledAt: 5, now: 15))
    }

    /// Born hidden, and says so.
    @Test func startsHidden() {
        let overlay = StatsOverlayLayer()
        #expect(overlay.isVisible == false)
        #expect(overlay.layer.isHidden)
        #expect(overlay.layer.opacity == 0)
    }

    /// Hide then show in one run-loop turn (StreamWindow.init, then the session's
    /// seed) must leave the panel shown; the show used to return early.
    @Test func showRightAfterHideWins() {
        let overlay = StatsOverlayLayer()
        overlay.setVisible(true)
        overlay.setVisible(false)
        overlay.setVisible(true)
        #expect(overlay.isVisible)
        #expect(overlay.layer.isHidden == false)
        #expect(overlay.layer.opacity == 1)
    }

    /// A hide completion that a later show overtook must not hide the panel.
    @Test func staleHideCompletionDoesNotHideAReshownPanel() {
        let overlay = StatsOverlayLayer()
        overlay.setVisible(true)
        overlay.setVisible(false)
        let staleGeneration = overlay.visibilityGeneration
        overlay.setVisible(true)
        overlay.finishHide(generation: staleGeneration)
        #expect(overlay.isVisible)
        #expect(overlay.layer.isHidden == false)
    }

    /// The current hide completion hides the layer.
    @Test func currentHideCompletionHidesTheLayer() {
        let overlay = StatsOverlayLayer()
        overlay.setVisible(true)
        overlay.setVisible(false)
        overlay.finishHide(generation: overlay.visibilityGeneration)
        #expect(overlay.isVisible == false)
        #expect(overlay.layer.isHidden)
    }
}
