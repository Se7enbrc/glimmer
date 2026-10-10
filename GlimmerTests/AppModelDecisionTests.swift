//
//  AppModelDecisionTests.swift
//
//  Decisions AppModel makes from values alone: what each route asks for,
//  which codec discount applies, the labels the launcher and menu bar print,
//  and the session receipt's key and wording. No model, defaults or network.
//

import Foundation
import Testing
@testable import Glimmer

struct AppModelDecisionTests {

    private func decision(_ mode: BitrateMode, dial: Int = 226_000, codec: Double = 0.8,
                          boost: Double = 1, gate: Double? = nil) -> BitrateDecision {
        BitrateDecision(mode: mode, dialKbps: dial, codecMultiplier: codec, boost: boost, radioGatePhyMbps: gate)
    }

    @MainActor @Test func theTopCodecSetsTheBudgetDiscount() {
        #expect(AppModel.codecBudgetMultiplier(for: [.av1]) == 0.80)
        #expect(AppModel.codecBudgetMultiplier(for: [.hevc, .h264]) == 0.80)
        #expect(AppModel.codecBudgetMultiplier(for: [.h264, .av1]) == 0.80)
        #expect(AppModel.codecBudgetMultiplier(for: [.h264]) == 1.0)
    }

    @Test func aRouteFillsInItsBoostForHighestQualityOnly() {
        let wired = AppModel.onRoute(decision(.highestQuality), route: .wired, phyRateMbps: nil)
        #expect(wired.boost == AppModel.wiredBitrateMultiplier)
        #expect(wired.dialKbps == 226_000 && wired.codecMultiplier == 0.8 && wired.mode == .highestQuality)
        #expect(AppModel.onRoute(decision(.bandwidthSaver, boost: 2), route: .wired, phyRateMbps: nil).boost == 1)
        #expect(AppModel.onRoute(decision(.highestQuality, boost: 2), route: .tunnel, phyRateMbps: nil).boost == 1)
        #expect(AppModel.onRoute(decision(.highestQuality, boost: 2), route: .unknown, phyRateMbps: nil).boost == 1)
        #expect(AppModel.onRoute(decision(.highestQuality), route: .wired, phyRateMbps: 480).radioGatePhyMbps == 480)
    }

    @Test func theWiredCapAppliesToHighestQualityNotTheSaver() {
        let boosted = decision(.highestQuality, dial: 400_000, codec: 1, boost: 2)
        #expect(AppModel.routeAskKbps(boosted, route: .wired) == AppModel.wiredBitrateCapKbps)
        let saver = decision(.bandwidthSaver, dial: 400_000, codec: 1, boost: 2)
        #expect(AppModel.routeAskKbps(saver, route: .wired) == AppModel.maxBitrateKbps)
        #expect(AppModel.routeAskKbps(decision(.highestQuality, boost: 2), route: .wired) == 361_600)
    }

    @Test func theAskNamesItsRouteAndKeepsOnlyAWithdrawableWiredBoost() {
        let wired = AppModel.routeAsk(decision(.highestQuality, boost: 2), route: .wired)
        #expect(wired == RouteAsk(kbps: 361_600, boost: 2, route: "wired"))
        let wifi = AppModel.routeAsk(decision(.highestQuality, boost: 1.5), route: .wifi)
        #expect(wifi.boost == 1 && wifi.route == "wifi" && wifi.kbps == 271_200)
    }

    @Test func theRadioGateTrimsAWiFiAsk() {
        let gated = AppModel.routeAsk(decision(.highestQuality, boost: 1.5, gate: 200), route: .wifi)
        #expect(gated.kbps == StreamPathMTU.wifiAskKbps(ask: 271_200, phyRateMbps: 200))
        #expect(gated.kbps < 271_200)
    }

    @MainActor @Test func aWindowTitleNamesThePCThenTheApp() {
        #expect(AppModel.streamWindowTitle(hostName: "Tower", appName: "Desktop") == "Tower - Desktop")
        #expect(AppModel.streamWindowTitle(hostName: "Tower", appName: "  ") == "Tower")
        #expect(AppModel.streamWindowTitle(hostName: "Tower", appName: " Steam ") == "Tower - Steam")
    }

    @Test func aPCIsDialedByDiscoveredThenTypedThenName() {
        func host(_ local: String?, _ manual: String?) -> Glimmer.Host {
            Host(id: "u", name: "tower", customName: "Den", localAddress: local, manualAddress: manual,
                 apps: [], lastConnected: nil, serverCertPEM: nil, appVersion: nil, macAddress: nil)
        }
        #expect(AppModel.routeAddress(host("192.0.2.10", "typed.local")) == "192.0.2.10")
        #expect(AppModel.routeAddress(host(nil, "typed.local")) == "typed.local")
        #expect(AppModel.routeAddress(host(nil, nil)) == "tower")
    }

    @Test func theMenuBarNamesTheLinkOrSaysNothing() {
        #expect(MenuBarPresentation.linkLabel(.wired) == "Wired")
        #expect(MenuBarPresentation.linkLabel(.wifi) == "Wi-Fi")
        #expect(MenuBarPresentation.linkLabel(.tunnel) == "VPN")
        #expect(MenuBarPresentation.linkLabel(.unknown) == nil)
    }

    @Test func aReceiptKeepsItsSharedKeyAndReadsQuietly() throws {
        #expect(SessionReceiptStore.key(hostId: "0123ABCD", width: 2560, height: 1440, refreshHz: 120)
            == "glimmer.lastSession.0123ABCD.2560x1440@120")
        func receipt(_ seconds: TimeInterval, rtt: Double?) -> SessionReceipt {
            SessionReceipt(durationSeconds: seconds, medianRttMs: rtt, avgGoodputMbps: nil,
                           width: 1920, height: 1080, refreshHz: 60, date: Date(timeIntervalSince1970: 1_765_400_000))
        }
        #expect(receipt(7_942, rtt: 12.4).summaryLine == "2h 12m · 12 ms median")
        #expect(receipt(2_300, rtt: nil).summaryLine == "38m")
        #expect(receipt(3_600, rtt: 9.6).summaryLine == "1h 0m · 10 ms median")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let json = try #require(try JSONSerialization.jsonObject(
            with: encoder.encode(receipt(300, rtt: 5))) as? [String: Any])
        #expect(json["date"] as? Int == 1_765_400_000)
        #expect(Set(json.keys) == ["durationSeconds", "medianRttMs", "width", "height", "refreshHz", "date"])
    }
}
