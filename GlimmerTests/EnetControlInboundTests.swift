// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  EnetControlInboundTests.swift
//
//  The inbound half of the control channel without a socket: ACK matching and the RTT
//  estimate, command framing, authentication bookkeeping and every host control message.
//

import CryptoKit
import Foundation
import Testing
@testable import Glimmer

/// Wire builders shared by the control-channel suites.
enum EnetFixture {
    static let key: [UInt8] = Array(0..<16).map { UInt8($0) }

    static func channel() throws -> EnetControlChannel {
        EnetControlChannel(host: .ipv4(.loopback), port: 0, controlConnectData: 0,
                           crypto: try ControlCrypto(rikey: key))
    }

    /// One datagram: the peer header, an optional sent time, then the commands back to back.
    static func datagram(_ commands: [[UInt8]], sentTime: UInt16? = 0x1234, compressed: Bool = false) -> [UInt8] {
        var w = ByteWriter()
        var flags: UInt16 = sentTime == nil ? 0 : Enet.headerFlagSentTime
        if compressed { flags |= Enet.headerFlagCompressed }
        w.u16BE(flags)
        if let sentTime { w.u16BE(sentTime) }
        for command in commands { w.append(command) }
        return w.bytes
    }

    static func reliable(relSeq: UInt16, _ payload: [UInt8], channel: UInt8 = Enet.ctrlChannelGeneric) -> [UInt8] {
        var w = ByteWriter()
        w.u8(Enet.cmdSendReliable | Enet.flagAcknowledge)
        w.u8(channel)
        w.u16BE(relSeq)
        w.u16BE(UInt16(payload.count))
        w.append(payload)
        return w.bytes
    }

    static func ack(channel: UInt8, relSeq: UInt16, sentTime: UInt16) -> [UInt8] {
        var w = ByteWriter()
        w.u8(Enet.cmdAcknowledge)
        w.u8(channel)
        w.u16BE(relSeq)
        w.u16BE(relSeq)
        w.u16BE(sentTime)
        return w.bytes
    }

    static func sealed(_ type: UInt16, _ payload: [UInt8], seq: UInt32 = 0) throws -> [UInt8] {
        try StreamCryptoTests.sealHostDirection(type: type, payload: payload, seq: seq, key: key)
    }

    /// Deliver one host control message as the first reliable on the generic channel.
    static func deliver(_ type: UInt16, _ payload: [UInt8], to channel: EnetControlChannel) throws {
        channel.onDatagram(datagram([reliable(relSeq: 1, try sealed(type, payload))]))
    }

    /// Open a client-direction envelope back to its inner [type LE][length LE][payload].
    static func openClient(_ envelope: [UInt8]) throws -> [UInt8] {
        let seq = UInt32(envelope[4]) | UInt32(envelope[5]) << 8 | UInt32(envelope[6]) << 16 | UInt32(envelope[7]) << 24
        let nonce = try AES.GCM.Nonce(data: StreamCryptoTests.controlIV(seq: seq, originator: 0x43))
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: Data(envelope[24...]), tag: Data(envelope[8..<24]))
        return [UInt8](try AES.GCM.open(box, using: SymmetricKey(data: Data(key))))
    }
}

/// Callbacks run synchronously on the test's thread, so plain storage is enough.
private final class Recorder<Value> {
    var values: [Value] = []
}

private struct AdaptiveTriggers: Equatable {
    let controller: UInt16, flags: UInt8, typeLeft: UInt8, typeRight: UInt8
    let left: [UInt8], right: [UInt8]
}

struct EnetControlInboundTests {

    private static func sentReliableKeys(_ channel: EnetControlChannel) -> [String] {
        channel.withState { channel.sentReliable.map { "\($0.channelID):\($0.reliableSequenceNumber)" } }
    }

    private static func termination(seq: UInt32 = 0) throws -> [UInt8] {
        try EnetFixture.sealed(CtrlV2.termination, [0x80, 0x03, 0x00, 0x23], seq: seq)
    }

    private static func terminationCodes(_ channel: EnetControlChannel) -> Recorder<Int32> {
        let codes = Recorder<Int32>()
        channel.onTerminated = { codes.values.append($0) }
        return codes
    }

    private static func logged(_ fragment: String) -> Int {
        LogStore.shared.snapshot().filter { $0.message.contains(fragment) }.count
    }

    // MARK: - ACK matching and the RTT estimate

    @Test func ackRemovesOnlyTheMatchingChannelAndSeedsTheRtt() throws {
        let channel = try EnetFixture.channel()
        channel.sendEnetPing()     // channel 0xFF, relSeq 1, first in line
        channel.sendPeriodicPing() // channel 0, relSeq 1
        channel.withState {
            channel.localSentByToken = [0x2222: channel.monotonicMs - 4]
            channel.lastAckRecvMs = 0xDEAD_0000
        }
        channel.onDatagram(EnetFixture.datagram([EnetFixture.ack(channel: 0, relSeq: 1, sentTime: 0x2222)]))

        #expect(Self.sentReliableKeys(channel) == ["255:1"])
        #expect(channel.unackedReliables.value == 1)
        #expect(channel.withState { channel.lastAckRecvMs } != 0xDEAD_0000)
        #expect(channel.withState { channel.localSentByToken.isEmpty })
        let rtt = try #require(channel.estimatedRtt())
        #expect(rtt.rttMs >= 4 && rtt.rttMs < 5)
        #expect(rtt.varianceMs == rtt.rttMs / 2)
    }

    @Test func ackWithAnUnknownTokenMatchesButTakesNoRttSample() throws {
        let channel = try EnetFixture.channel()
        channel.sendEnetPing()
        channel.withState { channel.localSentByToken = [:] }
        channel.onDatagram(EnetFixture.datagram([EnetFixture.ack(channel: 0xFF, relSeq: 1, sentTime: 0x9999)]))
        #expect(Self.sentReliableKeys(channel).isEmpty)
        #expect(channel.estimatedRtt() == nil)
    }

    /// ENet's gains: 1/8 of the error moves the mean, and the variance decays by 1/4 toward |error|/4.
    @Test(arguments: [(10.0, 4.0, 50.0, 15.0, 13.0), (100.0, 8.0, 20.0, 90.0, 26.0)])
    func rttFollowsEnetGains(start: Double, variance: Double, sample: Double, mean: Double, spread: Double) throws {
        let channel = try EnetFixture.channel()
        channel.withState {
            channel.hasRttSample = true
            channel.roundTripTime = start
            channel.rttVariance = variance
            channel.localSentByToken = [7: channel.monotonicMs - sample]
        }
        var reader = ByteReader([0x00, 0x01, 0x00, 0x07])
        channel.handleAcknowledge(ackChannelID: 0, &reader)
        let rtt = try #require(channel.estimatedRtt())
        #expect(abs(rtt.rttMs - mean) < 0.1)
        #expect(abs(rtt.varianceMs - spread) < 0.1)
    }

    @Test func lateAckCountsEveryGapBucket() throws {
        let channel = try EnetFixture.channel()
        let counters = TelemetryCounters.shared
        let before = [counters.enetGapOver20msTotal.value, counters.enetGapOver50msTotal.value,
                      counters.enetGapOver100msTotal.value]
        channel.withState {
            let sent = channel.serviceTimeMs &- 150
            channel.sentReliable = [SentReliable(channelID: 1, reliableSequenceNumber: 9, commandBytes: [],
                                                 sentAtMs: sent, firstSentAtMs: sent, attempts: 1)]
        }
        var reader = ByteReader([0x00, 0x09, 0x00, 0x00])
        channel.handleAcknowledge(ackChannelID: 1, &reader)
        let after = [counters.enetGapOver20msTotal.value, counters.enetGapOver50msTotal.value,
                     counters.enetGapOver100msTotal.value]
        #expect(zip(before, after).allSatisfy { $1 > $0 })
        #expect(Self.sentReliableKeys(channel).isEmpty)
    }

    @Test func truncatedAckChangesNothing() throws {
        let channel = try EnetFixture.channel()
        channel.sendEnetPing()
        var reader = ByteReader([0x00, 0x01, 0x00])
        channel.handleAcknowledge(ackChannelID: 0xFF, &reader)
        #expect(Self.sentReliableKeys(channel) == ["255:1"])
    }

    // MARK: - Datagram framing

    @Test func ackCommandKeepsParsingTheRestOfTheDatagram() throws {
        let channel = try EnetFixture.channel()
        let codes = Self.terminationCodes(channel)
        channel.sendEnetPing()
        channel.onDatagram(EnetFixture.datagram([
            EnetFixture.ack(channel: 0xFF, relSeq: 1, sentTime: 0),
            EnetFixture.reliable(relSeq: 1, try Self.termination())
        ]))
        #expect(Self.sentReliableKeys(channel).isEmpty)
        #expect(codes.values == [Int32(bitPattern: 0x8003_0023)])
    }

    @Test func compressedDatagramIsIgnored() throws {
        let channel = try EnetFixture.channel()
        let codes = Self.terminationCodes(channel)
        channel.onDatagram(EnetFixture.datagram([EnetFixture.reliable(relSeq: 1, try Self.termination())],
                                                compressed: true))
        #expect(codes.values.isEmpty)
    }

    @Test func unknownCommandStopsOnlyItsDatagram() throws {
        let channel = try EnetFixture.channel()
        let codes = Self.terminationCodes(channel)
        let message = EnetFixture.reliable(relSeq: 1, try Self.termination())
        channel.onDatagram(EnetFixture.datagram([[0x0D, 0, 0, 1], message]))
        #expect(codes.values.isEmpty)
        channel.onDatagram(EnetFixture.datagram([message]))
        #expect(codes.values == [Int32(bitPattern: 0x8003_0023)])
    }

    private static let terminationForms: [([UInt8], Int32)] = [
        ([0x80, 0x03, 0x00, 0x23], Int32(bitPattern: 0x8003_0023)), ([0x34, 0x12], 0x1234), ([0x01], -1), ([], -1)
    ]

    @Test(arguments: terminationForms)
    func terminationCodeReadsBothWireForms(payload: [UInt8], code: Int32) throws {
        #expect(try EnetFixture.channel().parseTerminationCode(payload) == code)
    }

    // MARK: - Authentication and unknown types

    @Test func unauthenticatedPayloadsAreCountedThenReportedOnce() throws {
        let channel = try EnetFixture.channel()
        channel.onDatagram(EnetFixture.datagram([EnetFixture.reliable(relSeq: 1, [0x01])]))
        channel.onDatagram(EnetFixture.datagram([EnetFixture.reliable(relSeq: 1, [0x02, 0x00, 0x00, 0x00])]))
        #expect(channel.withState { channel.rejectedInboundControl } == 2)
        channel.close()
        #expect(channel.withState { channel.rejectedInboundControl } == 0)
        #expect(Self.logged("ENet rejected 2 unauthenticated inbound control payload(s)") == 1)
    }

    @Test func unknownControlTypeIsLoggedOnceAndTotalledAtTeardown() throws {
        let channel = try EnetFixture.channel()
        let payload = (0..<20).map { UInt8($0) }
        for seq in UInt16(1)...2 {
            let sealed = try EnetFixture.sealed(0x7AB3, payload, seq: UInt32(seq))
            channel.onDatagram(EnetFixture.datagram([EnetFixture.reliable(relSeq: seq, sealed)]))
        }
        #expect(channel.withState { channel.ignoredControlCounts } == [0x7AB3: 2])
        #expect(Self.logged("type 0x7ab3 (20 bytes: 00 01 02 03 04 05 06 07 08 09 0a 0b 0c 0d 0e 0f...)") == 1)
        channel.interrupt()
        channel.close()
        #expect(channel.withState { channel.ignoredControlCounts.isEmpty })
        #expect(Self.logged("ENet ignored inbound control totals: 0x7ab3 -> 2") == 1)
    }

    @Test func teardownHookFiresOnceAcrossInterruptAndClose() throws {
        let channel = try EnetFixture.channel()
        let fired = Recorder<Bool>()
        channel.onTeardown = { fired.values.append(true) }
        channel.interrupt()
        channel.close()
        #expect(fired.values == [true])
        #expect(channel.interrupted.isSet)
    }

    // MARK: - Host control messages

    @Test func rgbLedAndPlayerLedsReachTheirCallbacks() throws {
        let rgb = Recorder<[UInt16]>()
        let leds = Recorder<[UInt16]>()
        let first = try EnetFixture.channel()
        first.onSetRgbLed = { rgb.values.append([$0, UInt16($1), UInt16($2), UInt16($3)]) }
        try EnetFixture.deliver(CtrlV2.setRgbLed, [0x02, 0x01, 10, 20, 30], to: first)
        let second = try EnetFixture.channel()
        second.onSetPlayerLeds = { leds.values.append([$0, UInt16($1), UInt16($2)]) }
        try EnetFixture.deliver(CtrlV2.setPlayerLeds, [0x01, 0x00, 0x05, 0x0A], to: second)
        #expect(rgb.values == [[0x0102, 10, 20, 30]])
        #expect(leds.values == [[1, 5, 10]])
    }

    /// Wire order is [controller][rate][type]; the callback hands over (controller, type, rate).
    @Test func motionEventSwapsRateAndTypeIntoCallbackOrder() throws {
        let channel = try EnetFixture.channel()
        let events = Recorder<[UInt16]>()
        channel.onSetMotionEvent = { events.values.append([$0, UInt16($1), $2]) }
        try EnetFixture.deliver(CtrlV2.setMotionEvent, [0x03, 0x00, 0xC8, 0x00, 0x02], to: channel)
        #expect(events.values == [[3, 2, 200]])
    }

    @Test func triggerRumbleAndAdaptiveTriggersParseLittleEndian() throws {
        let rumble = Recorder<[UInt16]>()
        let triggers = Recorder<AdaptiveTriggers>()
        let first = try EnetFixture.channel()
        first.onRumbleTriggers = { rumble.values.append([$0, $1, $2]) }
        try EnetFixture.deliver(CtrlV2.rumbleTriggers, [0x01, 0x00, 0x34, 0x12, 0x78, 0x56], to: first)
        let second = try EnetFixture.channel()
        second.onSetAdaptiveTriggers = {
            triggers.values.append(AdaptiveTriggers(controller: $0, flags: $1, typeLeft: $2, typeRight: $3,
                                                    left: $4, right: $5))
        }
        let left = Array(UInt8(1)...10)
        let right = Array(UInt8(11)...20)
        try EnetFixture.deliver(CtrlV2.setAdaptiveTriggers, [0x01, 0x00, 0x0C, 0x21, 0x26] + left + right, to: second)
        #expect(rumble.values == [[1, 0x1234, 0x5678]])
        #expect(triggers.values == [AdaptiveTriggers(controller: 1, flags: 0x0C, typeLeft: 0x21, typeRight: 0x26,
                                                     left: left, right: right)])
    }

    @Test(arguments: [(CtrlV2.setRgbLed, 4), (CtrlV2.setPlayerLeds, 3), (CtrlV2.setMotionEvent, 4),
                      (CtrlV2.rumbleTriggers, 5), (CtrlV2.setAdaptiveTriggers, 24), (CtrlV2.rumbleData, 9)])
    func truncatedControlMessageIsDropped(type: UInt16, length: Int) throws {
        let channel = try EnetFixture.channel()
        let calls = Recorder<UInt16>()
        channel.onSetRgbLed = { _, _, _, _ in calls.values.append(CtrlV2.setRgbLed) }
        channel.onSetPlayerLeds = { _, _, _ in calls.values.append(CtrlV2.setPlayerLeds) }
        channel.onSetMotionEvent = { _, _, _ in calls.values.append(CtrlV2.setMotionEvent) }
        channel.onRumbleTriggers = { _, _, _ in calls.values.append(CtrlV2.rumbleTriggers) }
        channel.onSetAdaptiveTriggers = { _, _, _, _, _, _ in calls.values.append(CtrlV2.setAdaptiveTriggers) }
        channel.onRumble = { _, _, _ in calls.values.append(CtrlV2.rumbleData) }
        let dropped = TelemetryCounters.shared.rumbleDroppedInvalidTotal.value
        try EnetFixture.deliver(type, [UInt8](repeating: 1, count: length), to: channel)
        #expect(calls.values.isEmpty)
        if type == CtrlV2.rumbleData {
            #expect(TelemetryCounters.shared.rumbleDroppedInvalidTotal.value > dropped)
        }
    }

    @Test func hdrMetadataParsesEveryFieldAndDisableNotifies() throws {
        let channel = try EnetFixture.channel()
        let modes = Recorder<Bool>()
        channel.onHdrMode = { modes.values.append($0) }
        var payload: [UInt8] = [1]
        for value in UInt16(1)...13 { payload += [UInt8(value * 3), UInt8(value)] }
        try EnetFixture.deliver(CtrlV2.hdrInfo, payload, to: channel)
        let metadata = try #require(channel.hdrMetadata())
        #expect(metadata == HdrMetadata(
            displayPrimariesRX: 0x0103, displayPrimariesRY: 0x0206, displayPrimariesGX: 0x0309,
            displayPrimariesGY: 0x040C, displayPrimariesBX: 0x050F, displayPrimariesBY: 0x0612,
            whitePointX: 0x0715, whitePointY: 0x0818, maxDisplayLuminance: 0x091B,
            minDisplayLuminance: 0x0A1E, maxContentLightLevel: 0x0B21, maxFrameAverageLightLevel: 0x0C24,
            maxFullFrameLuminance: 0x0D27))
        channel.handleHdrInfo([0])
        #expect(modes.values == [true, false])
        #expect(channel.hdrMetadata() == metadata)
        #expect(EnetControlChannel.parseHdrMetadata(Array(payload.prefix(26))) == nil)
    }

    // MARK: - RTT stamp bookkeeping

    @Test func stampMapDropsExpiredEntriesAtTheCap() throws {
        let channel = try EnetFixture.channel()
        channel.withState {
            for token in 0..<UInt16(EnetControlChannel.localSentMaxEntries) { channel.localSentByToken[token] = 0 }
            channel.recordLocalSent(token: 0xFFFF, atMs: EnetControlChannel.localSentTtlMs + 1)
        }
        #expect(channel.withState { channel.localSentByToken } == [0xFFFF: EnetControlChannel.localSentTtlMs + 1])
    }

    @Test func stampMapKeepsTheNewestHalfWhenEveryEntryIsYoung() throws {
        let channel = try EnetFixture.channel()
        let cap = EnetControlChannel.localSentMaxEntries
        channel.withState {
            for token in 0..<UInt16(cap) { channel.localSentByToken[token] = Double(token) }
            channel.recordLocalSent(token: 0xFFFF, atMs: Double(cap))
        }
        let kept = channel.withState { channel.localSentByToken }
        #expect(kept.count == cap / 2 + 1)
        #expect(kept[UInt16(cap - 1)] != nil && kept[UInt16(cap / 2)] != nil)
        #expect(kept[UInt16(cap / 2 - 1)] == nil && kept[0] == nil)
    }

    @Test func healthReportsTheOldestUnackedAndAckSilence() throws {
        let channel = try EnetFixture.channel()
        channel.withState {
            let now = channel.serviceTimeMs
            channel.lastAckRecvMs = now &- 200
            channel.sentReliable = [300, 100].map {
                SentReliable(channelID: 0, reliableSequenceNumber: 1, commandBytes: [],
                             sentAtMs: now &- $0, firstSentAtMs: now &- $0, attempts: 1)
            }
        }
        let health = channel.health()
        #expect(health.sentReliable == 2)
        #expect((300...310).contains(health.oldestUnackedMs))
        #expect((200...210).contains(health.sinceLastAckMs))
    }
}
