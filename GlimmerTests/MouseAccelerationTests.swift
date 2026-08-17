//
//  MouseAccelerationTests.swift
//
//  Coverage for the live-override guard in MouseAccelerationControl: with the
//  linear override engaged, IOKit reads the acceleration back as 0.0 - NOT the
//  negative sentinel value written - so a second engage (a concurrent second
//  copy, a raced restore, a crashed session's leftover) used to adopt Glimmer's
//  own override as "the user's prior" and the eventual restore stranded the
//  desktop at acceleration 0.0, persisted across launches. `resolvePrior` is
//  the pure discriminator (the crash sentinel holds the user's real curve);
//  the IOKit read/write plumbing around it is deliberately NOT exercised here -
//  a unit test must never write the machine's global pointer acceleration.
//

import Foundation
import Testing
@testable import Glimmer

struct MouseAccelerationTests {

    /// THE bug: override live (reads back 0.0), sentinel holds the user's real
    /// 1.5 - the restore chain must end at 1.5, never adopt the 0.0.
    @Test func liveOverrideAdoptsSentinelNotReadBack() {
        #expect(MouseAccelerationControl.resolvePrior(readBack: 0.0, sentinel: 1.5) == 1.5)
    }

    /// A stale sentinel (interrupted restore left it behind, but a real curve is
    /// live again): the fresh read is the truth - including when the user moved
    /// the slider since the sentinel was stamped.
    @Test func staleSentinelYieldsToLiveCurve() {
        #expect(MouseAccelerationControl.resolvePrior(readBack: 2.0, sentinel: 1.5) == 2.0)
    }

    /// A negative read-back with the sentinel stamped is still the live
    /// override (however the OS chooses to report it) - the sentinel wins.
    @Test func negativeReadBackAdoptsSentinel() {
        #expect(MouseAccelerationControl.resolvePrior(readBack: -1.0, sentinel: 1.5) == 1.5)
    }

    /// A corrupt (negative) sentinel must clamp to 0, never propagate a
    /// negative into the restore chain - restoring a negative would strand the
    /// pointer in linear mode permanently.
    @Test func corruptSentinelClampsToZero() {
        #expect(MouseAccelerationControl.resolvePrior(readBack: 0.0, sentinel: -3.0) == 0.0)
    }

    /// A genuine user 0.0 stamped by an earlier engage round-trips unchanged -
    /// the guard preserves, it never invents values.
    @Test func zeroSentinelRoundTrips() {
        #expect(MouseAccelerationControl.resolvePrior(readBack: 0.0, sentinel: 0.0) == 0.0)
    }
}
