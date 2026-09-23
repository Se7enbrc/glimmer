//
//  HostContextMenuTests.swift
//
//  The per-PC menu's decisions: when Quit shows, which PC counts as being
//  streamed, and how a failed quit reads in the launcher and the terminal.
//

import Foundation
import Testing
@testable import Glimmer

@MainActor
struct HostContextMenuTests {

    private let host = Host(
        id: "menu-test-pc", name: "tower", customName: "Tower", localAddress: "192.0.2.10", manualAddress: nil,
        apps: [], lastConnected: nil, serverCertPEM: nil, appVersion: nil, macAddress: nil)

    private func model(polled state: HostLiveStatus.State, hostID: String? = nil, age: TimeInterval = 0) -> AppModel {
        let model = AppModel()
        model.hostLiveStatus = HostLiveStatus(
            hostID: hostID ?? host.id, state: state, capturedAt: Date(timeIntervalSinceNow: -age))
        return model
    }

    @Test func quitIsOfferedOnlyForAFreshBusyReadingOfThisPC() {
        #expect(model(polled: .streamingApp(name: "Elden Ring")).polledChip(for: host)
            == .streamingElsewhere(appName: "Elden Ring"))
        #expect(model(polled: .streamingUnknownApp(id: 7)).polledChip(for: host) == .streamingElsewhere(appName: nil))
        #expect(model(polled: .idle).polledChip(for: host) == .ready(rttMs: nil))
        #expect(model(polled: .streamingApp(name: "x"), hostID: "other-pc").polledChip(for: host) == .unknown)
        #expect(model(polled: .streamingApp(name: "x"), age: HostLiveStatus.stale + 1).polledChip(for: host) == .unknown)
    }

    @Test func onlyThePCBeingStreamedCounts() {
        let model = AppModel()
        model.lastLaunchAttempt = (LibraryApp(id: 1, name: "Desktop", hdr: false, hidden: false), host)
        #expect(model.streamingHostID == nil)
        model.isStreaming = true
        #expect(model.streamingHostID == host.id)
    }

    /// Without a pin nothing is sent, and the launcher points at the fix.
    @Test func quittingOnAnUnpairedPCSaysHowToPairAgain() async {
        do {
            try await AppModel().quitRunningApp(on: host)
            Issue.record("a quit went out without a pin")
        } catch {
            #expect(AppModel.quitFailureMessage(for: error, hostName: host.displayName)
                == "Tower isn't paired with this Mac. Choose Pair Again… from the PC's ⋯ menu.")
        }
    }

    /// quitRunningApp words a refusal itself; the launcher and `glimmer quit` show it as is.
    @Test func aRefusedOrUnansweredQuitReadsTheSameInTheLauncherAndTheTerminal() {
        let refused = StreamError.launchFailed(
            "Tower wouldn't quit the app. If another device is streaming from it, stop that stream first.")
        for error in [refused, StreamError.hostUnreachable("timeout")] {
            #expect(AppModel.quitFailureMessage(for: error, hostName: host.displayName)
                == GlimmerCLI.message(for: error, host: host))
        }
    }
}
