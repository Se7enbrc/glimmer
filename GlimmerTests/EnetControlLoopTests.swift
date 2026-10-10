//
//  EnetControlLoopTests.swift
//
//  The outbound half of the control channel without a socket: every reliable command is
//  kept in sentReliable, so its exact wire bytes and the loop's decisions are readable there.
//

import Foundation
import Testing
@testable import Glimmer

struct EnetControlLoopTests {

    private static func commands(_ channel: EnetControlChannel) -> [[UInt8]] {
        channel.withState { channel.sentReliable.map(\.commandBytes) }
    }

    /// Split a SEND_RELIABLE command into its 4-byte header and the inner plaintext it seals.
    private static func openReliable(_ command: [UInt8]) throws -> (header: [UInt8], inner: [UInt8]) {
        try #require(command.count > 6)
        let length = Int(command[4]) << 8 | Int(command[5])
        try #require(length == command.count - 6)
        return (Array(command[0..<4]), try EnetFixture.openClient(Array(command[6...])))
    }

    private static func entry(ageMs: UInt32, attempts: Int = 1, size: Int = 4,
                              now: UInt32) -> SentReliable {
        SentReliable(channelID: 0, reliableSequenceNumber: 1, commandBytes: [UInt8](repeating: 0x86, count: size),
                     sentAtMs: now &- ageMs, firstSentAtMs: now &- ageMs, attempts: attempts)
    }

    private static func attempts(_ channel: EnetControlChannel) -> [Int] {
        channel.withState { channel.sentReliable.map(\.attempts) }
    }

    // MARK: - Wire bytes

    @Test func transportPingIsReliableOnThePeerChannelAndWraps() throws {
        let channel = try EnetFixture.channel()
        channel.sendEnetPing()
        channel.withState { channel.peerOutgoingReliableSeq = 0xFFFF }
        channel.sendEnetPing()
        #expect(Self.commands(channel) == [[0x85, 0xFF, 0x00, 0x01], [0x85, 0xFF, 0x00, 0x00]])
        #expect(channel.unackedReliables.value == 2)
    }

    @Test func periodicPingSealsTheKeepaliveWithAFreshNonceEachTime() throws {
        let channel = try EnetFixture.channel()
        channel.sendPeriodicPing()
        channel.sendPeriodicPing()
        let sent = Self.commands(channel)
        try #require(sent.count == 2)
        let keepalive: [UInt8] = [0x00, 0x02, 0x08, 0x00, 0x04, 0, 0, 0, 0, 0, 0, 0]
        for (index, command) in sent.enumerated() {
            let opened = try Self.openReliable(command)
            #expect(opened.header == [0x86, Enet.ctrlChannelGeneric, 0x00, UInt8(index + 1)])
            #expect(opened.inner == keepalive)
            #expect(Array(command[10..<14]) == [UInt8(index), 0, 0, 0])
        }
    }

    @Test func inputSealsAsInputDataOnTheFoldedChannel() throws {
        let channel = try EnetFixture.channel()
        channel.withState { channel.negotiatedChannelCount = 1 }
        #expect(channel.sendInputPacket([9, 8, 7], channel: Enet.ctrlChannelGamepadBase))
        let opened = try Self.openReliable(try #require(Self.commands(channel).first))
        #expect(opened.header == [0x86, Enet.ctrlChannelGeneric, 0x00, 0x01])
        #expect(opened.inner == [0x06, 0x02, 0x03, 0x00, 9, 8, 7])
    }

    @Test func inputPastTheMtuIsRefusedOnBothPaths() throws {
        let channel = try EnetFixture.channel()
        let oversized = [UInt8](repeating: 0, count: Int(Enet.defaultMTU))
        #expect(!channel.sendInputPacket(oversized, channel: Enet.ctrlChannelMouse))
        #expect(!channel.sendInputPacketUnreliable(oversized, channel: Enet.ctrlChannelSensorBase))
        #expect(Self.commands(channel).isEmpty)
        #expect(throws: EnetError.self) {
            try channel.sendEncryptedControlUnreliable(type: CtrlV2.inputData, payload: oversized,
                                                      channel: Enet.ctrlChannelSensorBase, label: "motion")
        }
    }

    @Test func recoveryRequestsCarryTheirPayloadsOnTheUrgentChannel() throws {
        let channel = try EnetFixture.channel()
        channel.invalidateReferenceFrames(from: 5, to: 9)
        _ = channel.drainPendingRecoveryRequests()
        channel.requestIdrFrame()
        _ = channel.drainPendingRecoveryRequests()
        let sent = Self.commands(channel)
        try #require(sent.count == 2)
        let rfi = try Self.openReliable(sent[0])
        let idr = try Self.openReliable(sent[1])
        #expect(rfi.header == [0x86, Enet.ctrlChannelUrgent, 0x00, 0x01])
        #expect(rfi.inner == [0x01, 0x03, 24, 0, 5, 0, 0, 0, 0, 0, 0, 0, 9, 0, 0, 0] + [UInt8](repeating: 0, count: 12))
        #expect(idr.header == [0x86, Enet.ctrlChannelUrgent, 0x00, 0x02])
        #expect(idr.inner == [0x02, 0x03, 0x02, 0x00, 0, 0])
    }

    @Test(arguments: zip(
        [EnetError.interrupted, .socketFailure("x"), .connectTimeout, .verifyConnectRejected("x"),
         .disconnected, .startFailed("x"), .mtuExceeded],
        ["ENet interrupted", "ENet UDP socket failure: x", "ENet CONNECT timed out (no VERIFY_CONNECT)",
         "ENet VERIFY_CONNECT rejected: x", "ENet peer disconnected during handshake",
         "ENet START packet failed: x", "ENet reliable payload exceeds MTU (fragmentation unsupported)"]))
    func everyEnetErrorNamesItsStage(error: EnetError, text: String) {
        #expect(error.description == text)
    }

    // MARK: - Retransmits

    @Test func unsampledLinkResendsAfterTheDefaultBackedOffTimeout() throws {
        let channel = try EnetFixture.channel()
        let resent = TelemetryCounters.shared.enetRetransmitTotal.value
        channel.withState {
            let now = channel.serviceTimeMs
            channel.sentReliable = [Self.entry(ageMs: 900, now: now), Self.entry(ageMs: 1100, now: now)]
        }
        channel.checkRetransmit()
        #expect(Self.attempts(channel) == [1, 2])
        #expect(channel.withState { Self.msSince(channel.sentReliable[1].sentAtMs, channel) } < 50)
        #expect(TelemetryCounters.shared.enetRetransmitTotal.value > resent)
    }

    @Test func sampledLinkUsesTheFlooredRttTimeoutWithCappedBackoff() throws {
        let channel = try EnetFixture.channel()
        channel.withState {
            channel.hasRttSample = true
            channel.roundTripTime = 10
            let now = channel.serviceTimeMs
            channel.sentReliable = [Self.entry(ageMs: 100, now: now), Self.entry(ageMs: 130, now: now),
                                    Self.entry(ageMs: 900, attempts: 7, now: now)]
        }
        channel.checkRetransmit()
        #expect(Self.attempts(channel) == [1, 2, 7])
    }

    @Test func dueResendsSpanSeveralDatagramsAndAllCount() throws {
        let channel = try EnetFixture.channel()
        channel.withState {
            let now = channel.serviceTimeMs
            channel.sentReliable = (0..<5).map { _ in Self.entry(ageMs: 1100, size: 400, now: now) }
        }
        channel.checkRetransmit()
        #expect(Self.attempts(channel) == [2, 2, 2, 2, 2])
    }

    @Test func deadPeerIsNeverRetransmitted() throws {
        let channel = try EnetFixture.channel()
        channel.withState {
            channel.disconnected = true
            channel.sentReliable = [Self.entry(ageMs: 5000, now: channel.serviceTimeMs)]
        }
        channel.checkRetransmit()
        #expect(Self.attempts(channel) == [1])
    }

    private static func msSince(_ then: UInt32, _ channel: EnetControlChannel) -> UInt32 {
        EnetControlChannel.msSince(then, now: channel.serviceTimeMs)
    }

    // MARK: - Control loop ticks

    @Test func tickStopsOnceThePeerIsDead() throws {
        let channel = try EnetFixture.channel()
        var state = channel.startControlLoop()
        channel.withState { channel.disconnected = true }
        #expect(!channel.controlLoopTick(&state))
    }

    @Test func tickSendsTheDuePeriodicPing() throws {
        let channel = try EnetFixture.channel()
        var state = channel.startControlLoop()
        #expect(channel.withState { channel.channelOutgoingReliableSeq[Enet.ctrlChannelGeneric] } == 1)
        state.lastPeriodicPingMs = channel.serviceTimeMs &- Enet.periodicPingIntervalMs
        #expect(channel.controlLoopTick(&state))
        #expect(channel.withState { channel.channelOutgoingReliableSeq[Enet.ctrlChannelGeneric] } == 2)
        #expect(Self.msSince(state.lastPeriodicPingMs, channel) < Enet.periodicPingIntervalMs)
    }

    @Test func tickSendsATransportPingOnlyAfterIdleSilence() throws {
        let channel = try EnetFixture.channel()
        var state = channel.startControlLoop()
        #expect(channel.controlLoopTick(&state))
        #expect(channel.withState { channel.peerOutgoingReliableSeq } == 0)
        channel.withState { channel.lastSendMs = channel.serviceTimeMs &- Enet.pingIntervalMs }
        state.lastPeriodicPingMs = channel.serviceTimeMs
        #expect(channel.controlLoopTick(&state))
        #expect(channel.withState { channel.peerOutgoingReliableSeq } == 1)
    }

    @Test func ackSilencePastThreeRttsMarksTheHostBehind() throws {
        let channel = try EnetFixture.channel()
        var state = channel.startControlLoop()
        channel.withState {
            channel.hasRttSample = true
            channel.roundTripTime = 10
            channel.lastAckRecvMs = channel.serviceTimeMs &- 100
        }
        #expect(channel.controlLoopTick(&state))
        #expect(channel.reliableBacklogged)
        channel.withState { channel.lastAckRecvMs = channel.serviceTimeMs }
        #expect(channel.controlLoopTick(&state))
        #expect(!channel.reliableBacklogged)
    }

    @Test func ackSilenceNearMissCountsOncePerCrossing() throws {
        let channel = try EnetFixture.channel()
        var state = channel.startControlLoop()
        let nearMisses = TelemetryCounters.shared.ackSilenceNearMissTotal.value
        channel.withState { channel.lastAckRecvMs = channel.serviceTimeMs &- 4000 }
        #expect(channel.controlLoopTick(&state))
        #expect(channel.ackSilenceNearMissArmed)
        #expect(TelemetryCounters.shared.ackSilenceNearMissTotal.value > nearMisses)
        channel.withState { channel.lastAckRecvMs = channel.serviceTimeMs }
        #expect(channel.controlLoopTick(&state))
        #expect(!channel.ackSilenceNearMissArmed)
    }

    @Test func tickTakesTheHealthSnapshotOncePerSecond() throws {
        let channel = try EnetFixture.channel()
        var state = channel.startControlLoop()
        let stale = channel.serviceTimeMs &- 2 * EnetControlChannel.healthSnapshotIntervalMs
        state.lastHealthSnapshotMs = stale
        #expect(channel.controlLoopTick(&state))
        #expect(Self.msSince(state.lastHealthSnapshotMs, channel) < EnetControlChannel.healthSnapshotIntervalMs)
    }

    @Test func syncLoopEndsOnInterruptAfterTheFirstKeepalive() throws {
        let channel = try EnetFixture.channel()
        channel.interrupt()
        channel.runControlLoopSync()
        #expect(channel.withState { channel.channelOutgoingReliableSeq[Enet.ctrlChannelGeneric] } == 1)
    }

    @Test func syncLoopEndsWhenThePeerDies() throws {
        let channel = try EnetFixture.channel()
        channel.withState { channel.disconnected = true }
        channel.runControlLoopSync()
        #expect(!channel.interrupted.isSet)
        #expect(channel.withState { channel.channelOutgoingReliableSeq[Enet.ctrlChannelGeneric] } == 1)
    }

    @Test func wakeReanchorsTheAckClockAndPingsALivePeer() throws {
        let live = try EnetFixture.channel()
        let dead = try EnetFixture.channel()
        for channel in [live, dead] { channel.withState { channel.lastAckRecvMs = 0xDEAD_0000 } }
        dead.withState { dead.disconnected = true }
        live.reanchorAckAndPing()
        dead.reanchorAckAndPing()
        #expect(Self.msSince(live.withState { live.lastAckRecvMs }, live) < 50)
        #expect(Self.msSince(dead.withState { dead.lastAckRecvMs }, dead) < 50)
        #expect(Self.commands(live) == [[0x85, 0xFF, 0x00, 0x01]])
        #expect(Self.commands(dead).isEmpty)
    }
}
