//
//  CruiseTraversalTests.swift
//
//  Pins the pure Cruise gain function (InputForwarder+Cruise.swift): the sacred
//  sub-knee aim band is exactly 1.0, the boost saturates at the resolution-derived
//  gMax above vFull, the ramp between is monotonic and C1-continuous at both ends,
//  a stale/post-gap dt collapses to identity, and gMax==1.0 (<=referenceWidth) is
//  fully inert at every velocity.
//

import Testing
@testable import Glimmer

struct CruiseTraversalTests {
    // 4K stream: gMax derives to 2.0 against the 1920 reference width.
    let gMax4K = CruiseTraversal.gMax(forStreamWidth: 3840)
    let vKnee = CruiseTraversal.defaultVKnee   // 1400
    let vFull = CruiseTraversal.defaultVFull   // 4500
    let dt = 0.008                              // ~120Hz batch interval (valid)

    private func gain(_ v: Double, dt: Double? = nil, gMax: Double? = nil) -> Double {
        CruiseTraversal.gain(velocity: v, dt: dt ?? self.dt, gMax: gMax ?? gMax4K,
                             vKnee: vKnee, vFull: vFull)
    }

    @Test func gMaxDerivesFromWidth() {
        #expect(gMax4K == 2.0)                                    // 3840/1920
        #expect(CruiseTraversal.gMax(forStreamWidth: 2560) == 2560.0 / 1920.0)  // ~1.33
        #expect(CruiseTraversal.gMax(forStreamWidth: 1920) == 1.0)
    }

    @Test func identityAtAndBelowKnee() {
        // The sacred aim band: exactly 1.0, no float drift, up to and including vKnee.
        #expect(gain(0) == 1.0)
        #expect(gain(500) == 1.0)
        #expect(gain(vKnee) == 1.0)
        #expect(gain(vKnee - 0.001) == 1.0)
    }

    @Test func fullGainAtAndAboveVFull() {
        #expect(gain(vFull) == gMax4K)
        #expect(gain(vFull + 1000) == gMax4K)
        #expect(gain(50_000) == gMax4K)
    }

    @Test func rampIsMonotonicAndBoundedBetween() {
        // Strictly increasing from 1.0 toward gMax across the knee→full band.
        var prev = gain(vKnee)
        var v = vKnee + 50
        while v < vFull {
            let g = gain(v)
            #expect(g > prev)                 // monotonic ramp
            #expect(g > 1.0 && g < gMax4K)    // bounded strictly inside
            prev = g
            v += 50
        }
    }

    @Test func continuousAtBothEnds() {
        // C1 smoothstep: value continuity at both knees (slope is 0 there too).
        let eps = 0.5
        #expect(abs(gain(vKnee + eps) - 1.0) < 1e-3)
        #expect(abs(gain(vFull - eps) - gMax4K) < 1e-3)
    }

    @Test func staleDtIsIdentity() {
        // A post-gap / stale dt (>0.1s) forces identity even at flick speed.
        #expect(gain(vFull, dt: 0.2) == 1.0)
        #expect(gain(vFull, dt: 0) == 1.0)
        #expect(gain(vFull, dt: -1) == 1.0)
    }

    @Test func inertWhenGMaxIsOne() {
        // <=1080p (gMax clamps to 1.0) is provably inert at every velocity.
        let inert = CruiseTraversal.gMax(forStreamWidth: 1920)
        #expect(inert == 1.0)
        for v in stride(from: 0.0, through: 20_000, by: 250) {
            #expect(gain(v, gMax: inert) == 1.0)
        }
        // 1080p width derives the same inert ceiling.
        #expect(CruiseTraversal.gMax(forStreamWidth: 1080) == 1.0)
    }
}
