//
//  HostsStoreTests.swift
//
//  The paired-PC store and its poller: what a PC that replaces the selection
//  gets, and how often it's polled.
//

import Foundation
import Testing
@testable import Glimmer

struct HostsStoreTests {

    @MainActor @Test func theClosedLauncherPollStaysFresh() {
        let tolerance: TimeInterval = 2, probeTimeout: TimeInterval = 2
        #expect(AppModel.idleHostStatusPollSeconds + tolerance + probeTimeout < HostLiveStatus.stale)
    }

    private static func host(_ id: String, address: String) -> Glimmer.Host {
        Glimmer.Host(id: id, name: id, customName: nil, localAddress: address, manualAddress: nil, apps: [],
                     lastConnected: nil, serverCertPEM: nil, appVersion: nil, gfeVersion: nil, macAddress: nil)
    }

    @MainActor @Test func aPCThatReplacesTheSelectionGetsAFreshChipAndPoll() {
        let model = AppModel()
        defer { model.hostStatusTask?.cancel() }
        model.selectedHost = Self.host("tower", address: "192.0.2.10")
        model.hostLiveStatus = HostLiveStatus(hostID: "tower", state: .idle, rttMs: 3,
                                              sunshineVersion: "2026.1", capturedAt: Date())
        let towerPoll = model.hostStatusTask
        // What loadHosts does once tower is unpaired.
        model.selectedHost = Self.host("den", address: "192.0.2.20")
        #expect(model.hostLiveStatus == nil)
        #expect(model.hostStatusTask != nil)
        #expect(model.hostStatusTask != towerPoll)
    }

    @MainActor @Test func reloadingTheSamePCKeepsItsChipAndPoll() {
        let model = AppModel()
        defer { model.hostStatusTask?.cancel() }
        let tower = Self.host("tower", address: "192.0.2.10")
        model.selectedHost = tower
        let status = HostLiveStatus(hostID: "tower", state: .idle, rttMs: 3, sunshineVersion: nil, capturedAt: Date())
        model.hostLiveStatus = status
        let poll = model.hostStatusTask
        // Every activation reloads the list and reassigns the same PC.
        model.selectedHost = tower
        #expect(model.hostLiveStatus == status)
        #expect(model.hostStatusTask == poll)
    }
}
