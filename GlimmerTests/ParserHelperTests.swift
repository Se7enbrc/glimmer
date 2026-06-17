//
//  ParserHelperTests.swift
//
//  Pure helpers on the untrusted-network-input surface that are reachable from
//  the test bundle (@testable exposes `internal`, NOT `private`).
//
//  Reachable here: RtpAudioQueue.isBefore16 (internal static) - the wrap-safe
//  16-bit RTP sequence-number comparison from Limelight-internal.h:76.
//
//  Deliberately NOT covered (all declared `private`, so @testable can't see
//  them): VideoDepacketizer.isIdrFrameStart / splitAnnexBParamSets,
//  RtpAudioQueue.padShard / appendRtpHeader, and
//  RtpVideoQueue+Reconstruct.buildShards. Testing those would require either
//  loosening their access level (a production change outside this task's scope)
//  or driving a live queue/clock (explicitly out of scope - tests must stay
//  deterministic and host-free).
//

import Foundation
import Testing
@testable import Glimmer

struct ParserHelperTests {

    // MARK: - RtpAudioQueue.isBefore16 (wrap-safe 16-bit sequence compare)
    //
    // Definition: isBefore16(x, y) == (x &- y) > 0x7FFF. "x is before y" within
    // half the 16-bit space, accounting for wraparound. The midpoint (exactly
    // 0x8000 apart) is the documented boundary.

    @Test func isBefore16SimpleOrdering() {
        #expect(RtpAudioQueue.isBefore16(0, 1))
        #expect(RtpAudioQueue.isBefore16(10, 20))
        #expect(!RtpAudioQueue.isBefore16(20, 10))
        #expect(!RtpAudioQueue.isBefore16(1, 0))
    }

    @Test func isBefore16EqualIsNotBefore() {
        // x &- x == 0, which is not > 0x7FFF.
        #expect(!RtpAudioQueue.isBefore16(0, 0))
        #expect(!RtpAudioQueue.isBefore16(0x1234, 0x1234))
        #expect(!RtpAudioQueue.isBefore16(0xFFFF, 0xFFFF))
    }

    @Test func isBefore16WrapsAround() {
        // The whole point: 0xFFFF is "before" 0x0001 (it precedes it on the
        // wire despite the larger raw value).
        #expect(RtpAudioQueue.isBefore16(0xFFFF, 0x0001))
        #expect(RtpAudioQueue.isBefore16(0xFFFE, 0x0000))
        // And the reverse is "after".
        #expect(!RtpAudioQueue.isBefore16(0x0001, 0xFFFF))
        #expect(!RtpAudioQueue.isBefore16(0x0000, 0xFFFE))
    }

    @Test func isBefore16HalfSpaceBoundary() {
        // Distance exactly 0x8000: (0 &- 0x8000) == 0x8000 > 0x7FFF -> before.
        #expect(RtpAudioQueue.isBefore16(0x0000, 0x8000))
        // (0 &- 0x7FFF) == 0x8001 > 0x7FFF -> 0 IS before 0x7FFF (it's the
        // farther-back wrap distance that counts).
        #expect(RtpAudioQueue.isBefore16(0x0000, 0x7FFF))
        // The exact NOT-before boundary: (0x7FFF &- 0) == 0x7FFF, NOT > 0x7FFF.
        #expect(!RtpAudioQueue.isBefore16(0x7FFF, 0x0000))
        // (0x7FFF &- 0xFFFF) = 0x8000 > 0x7FFF -> before.
        #expect(RtpAudioQueue.isBefore16(0x7FFF, 0xFFFF))
    }

    @Test func isBefore16IsAntisymmetricForDistinctNonAntipodal() {
        // For any pair NOT exactly 0x8000 apart, isBefore16(x,y) and
        // isBefore16(y,x) disagree (one true, one false).
        let pairs: [(UInt16, UInt16)] = [
            (1, 2), (100, 50), (0xFFFF, 3), (0x0005, 0xFFF0), (42, 0x9000)
        ]
        for (x, y) in pairs where (x &- y) != 0x8000 && x != y {
            #expect(RtpAudioQueue.isBefore16(x, y) != RtpAudioQueue.isBefore16(y, x))
        }
    }

    @Test func isBefore16AntipodalPairIsSymmetric() {
        // When exactly 0x8000 apart, BOTH directions are "before" (both
        // distances equal 0x8000 > 0x7FFF). A documented degenerate case.
        #expect(RtpAudioQueue.isBefore16(0x0000, 0x8000))
        #expect(RtpAudioQueue.isBefore16(0x8000, 0x0000))
    }
}
