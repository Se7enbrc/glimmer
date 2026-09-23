//
//  WiredBitrateTests.swift
//
//  The wire bitrate rule: codec discount, the boost and cap each route class
//  gets, the floor, and the connect-time withdrawal when the RTT says Wi-Fi.
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

    private func highestQualityAsk(_ route: HostRouteMonitor.RouteClass) -> Int {
        let pick = AppModel.routeBoost(route, wifiBoost: AppModel.wifiBitrateMultiplier)
        return AppModel.wireBitrateKbps(dial: 226_000, codecMultiplier: 0.8, boost: pick.boost, capKbps: pick.capKbps)
    }

    @Test func wiredRouteDoublesUnderTheHigherCap() {
        #expect(highestQualityAsk(.wired) == 361_600)
        #expect(AppModel.routeBoost(.wired).capKbps == 500_000)
    }

    @Test func wiFiRouteTakesHalfAsMuchAgainUnderTheFormulaCap() {
        #expect(highestQualityAsk(.wifi) == 271_200)
        #expect(AppModel.routeBoost(.wifi).capKbps == 300_000)
    }

    @Test func tunnelRouteKeepsTheUnboostedAsk() {
        // A VPN has no radio gate and no RTT withdrawal to trim a boost.
        #expect(highestQualityAsk(.tunnel) == 180_800)
    }

    @Test func unresolvedRouteKeepsTheUnboostedAsk() {
        #expect(highestQualityAsk(.unknown) == 180_800)
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
