//
//  WiredBitrateTests.swift
//
//  The wire bitrate rule: codec discount, the Ethernet multiplier, the floor
//  and the formula's cap.
//

import Testing
@testable import Glimmer

struct WiredBitrateTests {

    @Test func wiFiKeepsTheCodecDiscountedDial() {
        #expect(AppModel.wireBitrateKbps(dial: 226_000, codecMultiplier: 0.8, wired: false) == 180_800)
    }

    @Test func ethernetCarriesHalfAsMuchAgain() {
        #expect(AppModel.wireBitrateKbps(dial: 226_000, codecMultiplier: 0.8, wired: true) == 271_200)
    }

    @Test func capAndFloorStillApply() {
        #expect(AppModel.wireBitrateKbps(dial: 300_000, codecMultiplier: 1, wired: true) == AppModel.maxBitrateKbps)
        #expect(AppModel.wireBitrateKbps(dial: 1_000, codecMultiplier: 0.8, wired: false) == 5_000)
    }
}
