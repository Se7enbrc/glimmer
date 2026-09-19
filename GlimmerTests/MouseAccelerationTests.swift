//
//  MouseAccelerationTests.swift
//
//  Raw aim switches macOS linear pointer scaling on for the stream. When an
//  engagement is already live, the sentinel holds the user's flag and the
//  read-back is ours; a read-back of "curve on" means the sentinel went stale.
//

import Testing
@testable import Glimmer

struct MouseAccelerationTests {

    /// Live override: the read-back says linear (ours), the sentinel is the truth.
    @Test func liveOverrideAdoptsSentinel() {
        #expect(MouseAccelerationControl.resolvePrior(readBack: true, sentinel: false) == false)
        #expect(MouseAccelerationControl.resolvePrior(readBack: true, sentinel: true) == true)
    }

    /// A stale sentinel: the pointer reads "curve on", so that is what to restore.
    @Test func staleSentinelYieldsToLiveCurve() {
        #expect(MouseAccelerationControl.resolvePrior(readBack: false, sentinel: true) == false)
        #expect(MouseAccelerationControl.resolvePrior(readBack: false, sentinel: false) == false)
    }
}
