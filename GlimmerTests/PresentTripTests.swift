//
//  PresentTripTests.swift
//
//  The present-path trips: the deep reject streak opens an episode at depth 0, the one
//  signal a latched renderer leaves during warm handover, and the present-freeze trip
//  stays quiet on the burst that ends a network drought.
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

    /// A burst landing after a ~350ms drought meets a stale release clock, but
    /// the queue only just filled - that is not a wedge.
    @Test func postDroughtBurstDoesNotTrip() {
        let live = liveness(sinceRelease: 0.35, queueNonEmptyFor: 0.005)
        #expect(!StreamSession.presentStallTripped(live: live, inStartupGrace: false))
    }

    /// A latched gate holds frames continuously while nothing releases.
    @Test func queueHeldThroughStaleWindowTrips() {
        let live = liveness(sinceRelease: 0.35, queueNonEmptyFor: 0.3)
        #expect(StreamSession.presentStallTripped(live: live, inStartupGrace: false))
    }

    /// A refusing renderer drains the queue every tick, so the non-empty clock
    /// keeps restarting; the reject streak still lets the freeze trip on time.
    @Test func refusingRendererTripsDespiteFreshQueue() {
        let live = liveness(sinceRelease: 0.35, queueNonEmptyFor: 0.004, rejectStreak: 30)
        #expect(StreamSession.presentStallTripped(live: live, inStartupGrace: false))
    }

    private func liveness(
        sinceRelease: Double, queueNonEmptyFor: Double, rejectStreak: Int = 0
    ) -> FramePacer.LivenessSnapshot {
        FramePacer.LivenessSnapshot(
            secondsSinceLastTick: 0.004, secondsSinceLastRelease: sinceRelease, depth: 2,
            secondsQueueNonEmpty: queueNonEmptyFor, running: true, totalTicks: 5000,
            totalReleases: 4000, streamFrameIntervalSeconds: 1.0 / 120, adaptiveTargetDepth: 1,
            recentTicksPerSecond: 120, recentReleasesPerSecond: 120, tickDeficitSeconds: 0,
            expectedTickHz: 120, tickDeficitModeActive: false, presentRejectStreak: rejectStreak)
    }
}
