//
//  WiredBitrateTests.swift
//
//  The wire bitrate rule: codec discount, the wired boost and its cap, the
//  floor, and the connect-time withdrawal when the RTT says Wi-Fi.
//

import Testing
@testable import Glimmer

struct WiredBitrateTests {

    @Test func wiFiAsksForHalfAsMuchAgainUnderTheFormulaCap() {
        #expect(AppModel.wireBitrateKbps(dial: 226_000, codecMultiplier: 0.8, boost: 1, capKbps: 300_000) == 180_800)
        #expect(AppModel.wireBitrateKbps(dial: 226_000, codecMultiplier: 0.8,
                                         boost: AppModel.wifiBitrateMultiplier, capKbps: AppModel.maxBitrateKbps) == 271_200)
    }

    @Test func wiredEndToEndAsksForTwiceAsMuch() {
        #expect(AppModel.wireBitrateKbps(dial: 226_000, codecMultiplier: 0.8,
                                         boost: AppModel.wiredBitrateMultiplier,
                                         capKbps: AppModel.wiredBitrateCapKbps) == 361_600)
    }

    @Test func capAndFloorStillApply() {
        #expect(AppModel.wireBitrateKbps(dial: 300_000, codecMultiplier: 1, boost: 2, capKbps: 500_000) == 500_000)
        #expect(AppModel.wireBitrateKbps(dial: 1_000, codecMultiplier: 0.8, boost: 1, capKbps: 300_000) == 5_000)
    }

    @Test func wiFiRadioGateCapsTheAskAtAShareOfThePhyRate() {
        #expect(StreamPathMTU.wifiAskKbps(ask: 271_200, phyRateMbps: 1152) == 271_200)
        #expect(StreamPathMTU.wifiAskKbps(ask: 271_200, phyRateMbps: nil) == 271_200)
        #expect(StreamPathMTU.wifiAskKbps(ask: 271_200, phyRateMbps: 600) == 210_000)
        #expect(StreamPathMTU.wifiAskKbps(ask: 271_200, phyRateMbps: 144) == 50_400)
        #expect(StreamPathMTU.wifiAskKbps(ask: 271_200, phyRateMbps: 6) == 5_000)
    }

    @Test func rttWithdrawsTheBoostOnlyWhenAWiFiHopShows() {
        #expect(StreamPathMTU.wiredAskKbps(capped: 361_600, boost: 2, steadyRttMs: 0.4) == 361_600)
        #expect(StreamPathMTU.wiredAskKbps(capped: 361_600, boost: 2, steadyRttMs: nil) == 361_600)
        #expect(StreamPathMTU.wiredAskKbps(capped: 361_600, boost: 2, steadyRttMs: 4.2) == 180_800)
        #expect(StreamPathMTU.wiredAskKbps(capped: 180_800, boost: 1, steadyRttMs: 4.2) == 180_800)
    }
}
