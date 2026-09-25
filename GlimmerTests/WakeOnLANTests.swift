//
//  WakeOnLANTests.swift
//
//  The wake packet and where it goes: MAC normalisation (zeroed or malformed
//  fails closed), the 102-byte magic packet, the target list, what a wake that
//  sent nothing reports, and when a PC that woke gets a notification instead.
//

import Foundation
import os
import Testing
import UserNotifications
@testable import Glimmer

struct WakeOnLANTests {

    @Test func macNormalisesSeparatorsCaseAndShortOctets() {
        #expect(WakeOnLAN.normalizeMac("AA:BB:CC:DD:EE:FF") == "aa:bb:cc:dd:ee:ff")
        #expect(WakeOnLAN.normalizeMac("aa-bb-cc-dd-ee-ff") == "aa:bb:cc:dd:ee:ff")
        #expect(WakeOnLAN.normalizeMac("A:B:C:D:E:F") == "0a:0b:0c:0d:0e:0f")
    }

    @Test func zeroedOrMalformedMacFailsClosed() {
        #expect(WakeOnLAN.normalizeMac("00:00:00:00:00:00") == nil)
        #expect(WakeOnLAN.normalizeMac("0:0:0:0:0:0") == nil)
        #expect(WakeOnLAN.normalizeMac("aa:bb:cc:dd:ee") == nil)
        #expect(WakeOnLAN.normalizeMac("zz:bb:cc:dd:ee:ff") == nil)
        #expect(WakeOnLAN.normalizeMac(nil) == nil)
        #expect(WakeOnLAN.normalizeMac("") == nil)
    }

    @Test func magicPacketIsSixFFThenTheMacSixteenTimes() throws {
        let packet = try #require(WakeOnLAN.magicPacket(mac: "aa:bb:cc:dd:ee:ff"))
        #expect(packet.count == 102)
        #expect(Array(packet.prefix(6)) == [UInt8](repeating: 0xFF, count: 6))
        let mac: [UInt8] = [0xAA, 0xBB, 0xCC, 0xDD, 0xEE, 0xFF]
        for repeat_ in 0..<16 {
            let start = 6 + repeat_ * 6
            #expect(Array(packet[start..<start + 6]) == mac)
        }
        #expect(WakeOnLAN.magicPacket(mac: "00:00:00:00:00:00") == nil)
    }

    @Test func targetsCoverBroadcastsThenThePCWithSunshinesPortsToo() {
        let targets = WakeOnLAN.targets(
            hostAddresses: ["192.168.1.50", nil, " tower.local ", "192.168.1.50"],
            broadcasts: ["192.168.1.255", "255.255.255.255"])
        #expect(targets.map(\.host) == ["255.255.255.255", "192.168.1.255", "192.168.1.50", "tower.local"])
        #expect(targets[0].ports == [9, 47009])
        #expect(targets[1].ports == [9, 47009])
        for target in targets.dropFirst(2) {
            #expect(target.ports == [9, 47009, 47998, 47999, 48000, 48002, 48010])
        }
    }

    @Test func aPCAddressThatIsABroadcastGetsOnlyTheWakePorts() {
        let targets = WakeOnLAN.targets(hostAddresses: ["255.255.255.255"], broadcasts: [])
        #expect(targets.count == 1)
        #expect(targets[0].ports == [9, 47009])
    }

    private func tower(mac: String) -> Glimmer.Host {
        Glimmer.Host(id: "tower", name: "tower", customName: nil, localAddress: "192.0.2.10", manualAddress: nil,
                     apps: [], lastConnected: nil, serverCertPEM: nil, appVersion: nil, macAddress: mac)
    }

    @MainActor @Test func aWakeThatSendsNothingStopsAtOnce() async {
        let started = OSAllocatedUnfairLock(initialState: ContinuousClock.now)
        let outcome = await AppModel().sendWakeAndWait(tower(mac: "aa:bb:cc:dd:ee:ff"), waitSeconds: 90) { _, _ in
            started.withLock { $0 = .now }
            return 0
        }
        #expect(outcome == .couldNotSend)
        #expect(outcome.failureReason == .couldNotSend)
        #expect(ContinuousClock.now - started.withLock { $0 } < .seconds(5))
    }

    @MainActor @Test func aPCWithoutAMacIsNotWoken() async {
        let outcome = await AppModel().sendWakeAndWait(tower(mac: "00:00:00:00:00:00"), waitSeconds: nil) { _, _ in 1 }
        #expect(outcome == .noMac)
        #expect(outcome.failureReason == nil)
    }

    /// Declined, not yet answered or set to None: the notice would never show, so
    /// Wake and Connect opens the stream as it did before notifications.
    @Test func aWakeFromAnotherAppNotifiesOnlyWhenTheNoticeCanShow() {
        #expect(WakeNotifier.shows(.authorized, style: .banner))
        #expect(WakeNotifier.shows(.authorized, style: .alert))
        #expect(!WakeNotifier.shows(.authorized, style: .none))
        #expect(!WakeNotifier.shows(.provisional, style: .banner))
        #expect(!WakeNotifier.shows(.denied, style: .banner))
        #expect(!WakeNotifier.shows(.notDetermined, style: .banner))
    }

    @MainActor @Test func wakeReadinessUsesTheFullControlRequestTimeout() {
        #expect(AppModel.wakeReadinessTimeout == NetworkClient.controlTimeout)
        #expect(AppModel.wakeReadinessTimeout > 1)
    }

    @MainActor @Test func connectResponseSelectsAndDispatchesHostLoadedDuringBootstrap() async {
        let model = AppModel()
        let host = Glimmer.Host(id: "requested", name: "Requested", customName: nil, localAddress: nil,
                                manualAddress: nil,
                                apps: [LibraryApp(id: 1, name: "Desktop", hdr: false, hidden: false)],
                                lastConnected: nil, serverCertPEM: "pin", appVersion: nil, macAddress: nil)
        let bootstrap = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(20))
            model.hosts = [host]
        }

        var dispatched: (Glimmer.Host, Bool)?
        await WakeNotifier.shared.routeResponse(action: "wake.connect", category: "wake.awake",
                                                hostID: host.id, model: model, bootstrap: bootstrap) { host, connect in
            dispatched = (host, connect)
        }

        #expect(dispatched?.0.id == host.id)
        #expect(dispatched?.1 == true)
        #expect(model.selectedHost == nil)
        #expect(model.lastLaunchAttempt == nil)
    }
}
