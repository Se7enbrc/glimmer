// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  HostStatusPollerTests.swift
//
//  One readiness poll end to end: the TCP probe's verdict, then /serverinfo from a fake Sunshine
//  deciding Ready, the running app, Trust needed, or a forgiving Ready on a failed reply.
//

import Foundation
import Testing
@testable import Glimmer

@MainActor
struct HostStatusPollerTests {

    private let hostID = "poll-\(UUID().uuidString)"

    private func model(apps: [LibraryApp] = []) -> AppModel {
        let model = AppModel()
        model.selectedHost = Glimmer.Host(id: hostID, name: "Tower", customName: nil, localAddress: "192.0.2.10",
                                          manualAddress: nil, apps: apps, lastConnected: nil, serverCertPEM: nil,
                                          appVersion: nil, macAddress: nil)
        model.hostStatusTask?.cancel()
        return model
    }

    private func poll(_ model: AppModel, _ sunshine: FakeSunshine, appListFor: Int? = 0,
                      pin: String? = nil) async -> (appListFor: Int?, noPath: Bool) {
        await model.pollHostStatusOnce(
            for: hostID, appListFor: appListFor, probe: { _, _, _ in .reachable(rttMs: 7) },
            makeClient: { info in
                var server = info
                server.serverCertPEM = pin ?? info.serverCertPEM
                return sunshine.client(server)
            })
    }

    @Test func anIdlePCIsReadyWithItsVersionAndRtt() async {
        let model = model()
        model.hostUnreachableStreak = 2
        model.wakeFailedHostID = hostID
        model.wakeFailureReason = .noAnswer
        let sunshine = FakeSunshine { _ in
            FakeSunshine.xml("<appversion>7.1.431.-1</appversion><currentgame>0</currentgame>")
        }
        let result = await poll(model, sunshine)

        #expect(result.appListFor == 0 && !result.noPath)
        #expect(model.hostLiveStatus?.state == .idle)
        #expect(model.hostLiveStatus?.rttMs == 7 && model.hostLiveStatus?.sunshineVersion == "7.1.431.-1")
        #expect(model.hostUnreachableStreak == 0 && model.wakeFailedHostID == nil && model.wakeFailureReason == nil)
        #expect(sunshine.requests.map(\.path) == ["/serverinfo"])
        #expect(sunshine.requests.first?.port == 47989)
    }

    @Test func aRunningAppIsNamedFromTheLibraryOrByItsId() async {
        let named = model(apps: [LibraryApp(id: 42, name: "Portal 2", hdr: false, hidden: false)])
        _ = await poll(named, FakeSunshine { _ in FakeSunshine.xml("<currentgame>42</currentgame>") })
        #expect(named.hostLiveStatus?.state == .streamingApp(name: "Portal 2"))

        let unknown = model()
        let result = await poll(unknown, FakeSunshine { _ in FakeSunshine.xml("<currentgame>77</currentgame>") },
                                appListFor: 77)
        #expect(unknown.hostLiveStatus?.state == .streamingUnknownApp(id: 77))
        #expect(result.appListFor == 77)
    }

    @Test func aChangedCertificateShowsTrustNeededNotAsleep() async {
        let model = model()
        let sunshine = FakeSunshine { _ in throw StreamError.hostUnreachable("pinned host cert mismatch") }
        _ = await poll(model, sunshine, pin: "old-pin")
        #expect(model.hostLiveStatus?.state == .certMismatch)
        #expect(model.hostLiveStatus?.rttMs == 7)
        #expect(sunshine.requests.map(\.tls) == [true])
    }

    @Test func aFailedReplyFromAnAnsweringPCStillShowsReady() async {
        let refused = model()
        _ = await poll(refused, FakeSunshine { _ in FakeSunshine.xml("", status: 503) })
        #expect(refused.hostLiveStatus?.state == .idle)

        let broken = model()
        _ = await poll(broken, FakeSunshine { _ in throw URLError(.networkConnectionLost) })
        #expect(broken.hostLiveStatus?.state == .idle && broken.hostLiveStatus?.rttMs == 7)
    }

    @Test func noRouteOrNoAnswerNeverAsksSunshine() async {
        let model = model()
        let sunshine = FakeSunshine { _ in FakeSunshine.xml("") }
        let noPath = await model.pollHostStatusOnce(for: hostID, appListFor: 3, probe: { _, _, _ in .noPath },
                                                    makeClient: { sunshine.client($0) })
        #expect(noPath.appListFor == 3 && noPath.noPath)

        let offline = await model.pollHostStatusOnce(for: hostID, appListFor: 3, probe: { _, _, _ in .unreachable },
                                                     makeClient: { sunshine.client($0) }, macHasRoute: false)
        #expect(offline.noPath)

        var missed: (String, String)?
        let miss = await model.pollHostStatusOnce(for: hostID, appListFor: 3, probe: { _, _, _ in .unreachable },
                                                  makeClient: { sunshine.client($0) }, macHasRoute: true,
                                                  publishMiss: { missed = ($0, $1) })
        #expect(!miss.noPath && missed?.0 == hostID && missed?.1 == hostID)
        #expect(sunshine.requests.isEmpty)
        #expect(model.hostLiveStatus == nil)
    }

    @Test func aPollForAnotherPCPublishesNothing() async {
        let model = model()
        let sunshine = FakeSunshine { _ in FakeSunshine.xml("") }
        let result = await model.pollHostStatusOnce(for: "den", appListFor: 5, probe: { _, _, _ in .reachable(rttMs: 1) },
                                                    makeClient: { sunshine.client($0) })
        #expect(result.appListFor == 5 && !result.noPath)
        #expect(sunshine.requests.isEmpty && model.hostLiveStatus == nil)
    }
}
