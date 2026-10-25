// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Compatibility entry points preserve the measured Mac launch gates until hardware trials pass.
package typealias RouteBitratePolicy = BandwidthPolicy

extension BandwidthPolicy {
    package enum Route: String, Sendable { case wired, wifi, tunnel, unknown }

    package struct Settings: Sendable {
        package let wiredBoost: Double
        package let wifiBoost: Double
        package let wiredCapKbps: Int
        package let capKbps: Int

        package init(wiredBoost: Double, wifiBoost: Double, wiredCapKbps: Int, capKbps: Int) {
            self.wiredBoost = wiredBoost
            self.wifiBoost = wifiBoost
            self.wiredCapKbps = wiredCapKbps
            self.capKbps = capKbps
        }
    }

    package static func boost(_ route: Route, settings: Settings) -> (boost: Double, capKbps: Int) {
        switch route {
        case .wired: (settings.wiredBoost, settings.wiredCapKbps)
        case .wifi: (settings.wifiBoost, settings.capKbps)
        case .tunnel, .unknown: (1, settings.capKbps)
        }
    }

    package static func wireBitrateKbps(dial: Int, codecMultiplier: Double, boost: Double, capKbps: Int) -> Int {
        let scaled = Double(dial) * codecMultiplier * boost
        let clamped = min(scaled, Double(capKbps))
        return min(max(5_000, Int(clamped.rounded())), capKbps)
    }

    package static func askKbps(_ decision: BitrateDecision, route: Route, settings: Settings) -> Int {
        let cap = decision.mode == .highestQuality ? boost(route, settings: settings).capKbps : settings.capKbps
        return wireBitrateKbps(dial: decision.dialKbps, codecMultiplier: decision.codecMultiplier,
                               boost: decision.boost, capKbps: cap)
    }

    package static func ask(_ decision: BitrateDecision, route: Route, settings: Settings) -> RouteAsk {
        RouteAsk(kbps: StreamPathMTU.wifiAskKbps(ask: askKbps(decision, route: route, settings: settings),
                                               phyRateMbps: decision.radioGatePhyMbps),
                 boost: rttWithdrawableBoost(decision, route: route), route: route.rawValue)
    }

    package static func onRoute(_ decision: BitrateDecision, route: Route,
                                phyRateMbps: Double?, settings: Settings) -> BitrateDecision {
        var decision = decision
        decision.boost = decision.mode == .highestQuality ? boost(route, settings: settings).boost : 1
        decision.radioGatePhyMbps = phyRateMbps
        return decision
    }

    package static func rttWithdrawableBoost(_ decision: BitrateDecision, route: Route) -> Double {
        route == .wired ? decision.boost : 1
    }

    package static func reconnectAsk(
        _ launch: BitrateDecision, route: Route, phyRateMbps: Double?,
        selectedHostID: String?, sessionHostID: String, settings: Settings
    ) -> RouteAsk? {
        guard selectedHostID == sessionHostID, route != .unknown else { return nil }
        return ask(onRoute(launch, route: route, phyRateMbps: phyRateMbps, settings: settings),
                   route: route, settings: settings)
    }
}
