//
//  WakeOnLANTests.swift
//
//  The wake packet and where it goes: MAC normalisation (zeroed or malformed
//  fails closed), the 102-byte magic packet, and the target list.
//

import Testing
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

    @Test func targetsCoverBroadcastsThenTheHostOnBothPorts() {
        let targets = WakeOnLAN.targets(
            hostAddresses: ["192.168.1.50", nil, " tower.local ", "192.168.1.50"],
            broadcasts: ["192.168.1.255", "255.255.255.255"])
        #expect(targets.map(\.host) == ["255.255.255.255", "255.255.255.255", "192.168.1.255", "192.168.1.255",
                                        "192.168.1.50", "192.168.1.50", "tower.local", "tower.local"])
        #expect(Set(targets.map(\.port)) == [9, 47009])
    }
}
