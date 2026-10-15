// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

@testable import GlimmerEngine
import Testing

struct RouteBitratePolicyTests {
    private let settings = RouteBitratePolicy.Settings(wiredBoost: 3, wifiBoost: 1.25,
                                                       wiredCapKbps: 410_000, capKbps: 190_000)

    @Test func nativeSettingsAreInputsWhileRadioAndReconnectRulesStayShared() throws {
        let launch = BitrateDecision(mode: .highestQuality, dialKbps: 100_001,
                                     codecMultiplier: 0.8, boost: 3, radioGatePhyMbps: nil)
        let wired = try #require(RouteBitratePolicy.reconnectAsk(launch, route: .wired, phyRateMbps: nil,
            selectedHostID: "pc", sessionHostID: "pc", settings: settings))
        #expect(wired == RouteAsk(kbps: 240_002, boost: 3, route: "wired"))
        let wifi = try #require(RouteBitratePolicy.reconnectAsk(launch, route: .wifi, phyRateMbps: 200,
            selectedHostID: "pc", sessionHostID: "pc", settings: settings))
        #expect(wifi == RouteAsk(kbps: 70_000, boost: 1, route: "wifi"))
        #expect(RouteBitratePolicy.reconnectAsk(launch, route: .wired, phyRateMbps: nil,
            selectedHostID: "other", sessionHostID: "pc", settings: settings) == nil)
        #expect(RouteBitratePolicy.reconnectAsk(launch, route: .unknown, phyRateMbps: nil,
            selectedHostID: "pc", sessionHostID: "pc", settings: settings) == nil)
        #expect(launch.boost == 3 && launch.radioGatePhyMbps == nil)
    }

    @Test func requiredTakeoverRetainsTheConflictingApplication() {
        #expect(StreamFailure.connection(TakeoverRequired(appID: 42)) == .takeoverRequired(appID: 42))
    }

    @Test func saverAvoidsRouteBoostAndKeepsConfiguredCap() {
        let launch = BitrateDecision(mode: .bandwidthSaver, dialKbps: 250_000,
                                     codecMultiplier: 1, boost: 1, radioGatePhyMbps: nil)
        let routed = RouteBitratePolicy.onRoute(launch, route: .wired, phyRateMbps: nil, settings: settings)
        #expect(routed.boost == 1)
        #expect(RouteBitratePolicy.ask(routed, route: .wired, settings: settings).kbps == 190_000)
        #expect(RouteBitratePolicy.wireBitrateKbps(dial: 100_001, codecMultiplier: 0.8,
                                                  boost: .infinity, capKbps: 410_000) == 410_000)
        #expect(RouteBitratePolicy.wireBitrateKbps(dial: 1, codecMultiplier: 0.8,
                                                  boost: 1, capKbps: 190_000) == 5_000)
    }
}
