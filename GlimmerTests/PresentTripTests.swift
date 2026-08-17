//
//  PresentTripTests.swift
//
//  The renderer-starvation trip (wedge audit 2026-08-17): during warm handover
//  and the pre-first-release stretch of a fresh pacer, every submit
//  direct-presents - depth pins at 0 and totalReleases at 0, so every
//  pre-existing trip (presentStalled, tickDeficit: both require depth > 0;
//  linkDead: false on a ticking link) was structurally blind while a latched
//  renderer discarded every decoded frame forever. The deep consecutive
//  reject streak is the one signal that survives depth 0 - each increment is
//  proof a decoded frame reached willPresent and was refused - and it now
//  opens an episode in its own right.
//

import Foundation
import Testing
@testable import Glimmer

struct PresentTripTests {

    /// THE wedge shape: depth 0, zero releases, deep reject streak - the trip
    /// must open (and carry the rendererRejecting classification so the ladder
    /// selects the flush medicine, the proven cure for the latched renderer).
    @Test func depthZeroStarvationOpensEpisode() {
        let trip = StreamSession.PresentTrip(
            linkDead: false, presentStalled: false, tickDeficit: false,
            rendererRejecting: true, rendererStarved: true)
        #expect(trip.tripped)
    }

    /// Transient rejections below the starvation threshold classify but never
    /// trip on their own - the pre-existing contract, preserved.
    @Test func classificationAloneDoesNotTrip() {
        let trip = StreamSession.PresentTrip(
            linkDead: false, presentStalled: false, tickDeficit: false,
            rendererRejecting: true, rendererStarved: false)
        #expect(!trip.tripped)
    }

    /// Threshold boundary: 90 consecutive refusals trips, 89 does not.
    @Test func starvationThresholdBoundary() {
        #expect(StreamSession.rendererStarvationTripped(rejectStreak: 90, inStartupGrace: false))
        #expect(!StreamSession.rendererStarvationTripped(rejectStreak: 89, inStartupGrace: false))
    }

    /// Startup grace suppresses the trip - cadence-lock and priming churn must
    /// not masquerade as a wedge, same as every other trip.
    @Test func startupGraceSuppresses() {
        #expect(!StreamSession.rendererStarvationTripped(rejectStreak: 500, inStartupGrace: true))
    }

    /// The trip threshold must sit far above the classification threshold:
    /// classification re-aims an already-open episode cheaply; OPENING an
    /// episode from the streak alone demands the deep-wedge shape.
    @Test func tripThresholdFarAboveClassification() {
        #expect(StreamSession.rendererStarvationStreakTrip
            >= 10 * StreamSession.rendererRejectStreakTrip)
    }
}
