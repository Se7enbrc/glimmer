//
//  EnetControlChannelTests.swift
//
//  Most tests use no socket, so sends drop on the nil connection; callbacks and
//  stored state expose the results. One uses a loopback listener to read the ACKs.
//

import Foundation
import Network
import Testing
@testable import Glimmer

struct EnetControlChannelTests {

    private static let key: [UInt8] = Array(0..<16).map { UInt8($0) }
    /// SERVER_TERMINATED_CLOSED, a code the host really sends.
    private static let hostCode = Int32(bitPattern: 0x8003_0023)

    /// Collects onTerminated codes; the parser calls back synchronously.
    private final class Codes {
        var values: [Int32] = []
    }

    private static func makeChannel() throws -> (EnetControlChannel, Codes) {
        let channel = EnetControlChannel(host: "127.0.0.1", port: 9, controlConnectData: 0,
                                         crypto: try ControlCrypto(rikey: key))
        let codes = Codes()
        channel.onTerminated = { codes.values.append($0) }
        return (channel, codes)
    }

    /// Build one datagram carrying SEND_RELIABLE, with optional sent time and channel.
    private static func reliable(relSeq: UInt16, _ payload: [UInt8], channel: UInt8 = Enet.ctrlChannelGeneric,
                                 sentTime: UInt16 = 0, hasSentTime: Bool = true) -> [UInt8] {
        var w = ByteWriter()
        w.u16BE(hasSentTime ? Enet.headerFlagSentTime : 0)
        if hasSentTime { w.u16BE(sentTime) }
        w.u8(Enet.cmdSendReliable | Enet.flagAcknowledge)
        w.u8(channel)
        w.u16BE(relSeq)
        w.u16BE(UInt16(payload.count))
        w.append(payload)
        return w.bytes
    }

    private static func disconnect() -> [UInt8] {
        var w = ByteWriter()
        w.u16BE(Enet.headerFlagSentTime)
        w.u16BE(0)
        w.u8(Enet.cmdDisconnect | Enet.flagAcknowledge)
        w.u8(Enet.peerChannelID)
        w.u16BE(1)
        w.u32BE(0)
        return w.bytes
    }

    /// A genuine host TERMINATION (extended form: BE u32 code), sealed with the session key.
    private static func termination(seq: UInt32) throws -> [UInt8] {
        let code = UInt32(bitPattern: hostCode)
        let payload = [UInt8(code >> 24), UInt8((code >> 16) & 0xFF),
                       UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        return try StreamCryptoTests.sealHostDirection(
            type: CtrlV2.termination, payload: payload, seq: seq, key: key)
    }

    private static func urgentRelSeq(_ channel: EnetControlChannel) -> UInt16 {
        channel.withState { channel.channelOutgoingReliableSeq[Enet.ctrlChannelUrgent] ?? 0 }
    }

    // MARK: - Unauthenticated packets can't silence the channel

    @Test func forgedReliableDoesNotMakeGenuineMessagesStale() throws {
        let (channel, codes) = try Self.makeChannel()
        // A spoofed packet half the sequence space ahead, failing authentication.
        let forged: [UInt8] = [0x01, 0x00] + [UInt8](repeating: 0xAB, count: 30)
        channel.onDatagram(Self.reliable(relSeq: 0x7FFF, forged))
        channel.onDatagram(Self.reliable(relSeq: 1, try Self.termination(seq: 0)))
        #expect(codes.values == [Self.hostCode])
    }

    @Test func forgedFragmentDoesNotMakeGenuineMessagesStale() throws {
        let (channel, codes) = try Self.makeChannel()
        channel.onDatagram([0, 0] + Self.prefix(Enet.cmdSendFragment, relSeq: 0x7FFF))
        channel.inboundOrder[0]?.gapStartedMs = channel.serviceTimeMs &- (EnetInboundOrder.maxGapMs + 1)
        channel.onDatagram([0, 0])
        channel.onDatagram(Self.reliable(relSeq: 1, try Self.termination(seq: 0)))
        #expect(codes.values == [Self.hostCode])
    }

    // MARK: - Every peer death reaches the session exactly once

    @Test func hostDisconnectAfterConnectEndsTheSession() throws {
        let (channel, codes) = try Self.makeChannel()
        channel.onDatagram(Self.disconnect())
        #expect(codes.values == [-1])
    }

    @Test func terminationThenDisconnectFiresOnce() throws {
        let (channel, codes) = try Self.makeChannel()
        channel.onDatagram(Self.reliable(relSeq: 1, try Self.termination(seq: 0)))
        channel.onDatagram(Self.disconnect())
        channel.onDatagram(Self.reliable(relSeq: 2, try Self.termination(seq: 1)))
        #expect(codes.values == [Self.hostCode])
    }

    @Test func lateVerifyConnectKeepsTheCommandsBehindIt() throws {
        let (channel, codes) = try Self.makeChannel()
        channel.withState { channel.connected = true }
        // A VERIFY_CONNECT retransmitted after connect (40-byte body), then a TERMINATION.
        let verifyConnect = [Enet.cmdVerifyConnect | Enet.flagAcknowledge, Enet.peerChannelID, 0, 1]
            + [UInt8](repeating: 0, count: 40)
        let datagram = Self.reliable(relSeq: 1, try Self.termination(seq: 0))
        channel.onDatagram(Array(datagram[..<4]) + verifyConnect + datagram[4...])
        #expect(codes.values == [Self.hostCode])
    }

    @Test func ackSilenceCutoffThenLateTerminationFiresOnce() throws {
        let (channel, codes) = try Self.makeChannel()
        var state = channel.startControlLoop() // sends a ping, so a reliable is outstanding
        channel.withState { channel.lastAckRecvMs = channel.serviceTimeMs &- 20_000 }
        #expect(!channel.controlLoopTick(&state))
        channel.onDatagram(Self.reliable(relSeq: 1, try Self.termination(seq: 0)))
        #expect(codes.values == [-1])
    }

    // MARK: - IDR/RFI requests wake the control loop

    @Test func requestBurstWakesTheLoopOnce() throws {
        let (channel, _) = try Self.makeChannel()
        #expect(channel.recoveryWake.wait(timeout: .now()) == .timedOut)
        channel.invalidateReferenceFrames(from: 10, to: 11)
        channel.invalidateReferenceFrames(from: 12, to: 13)
        channel.requestIdrFrame()
        channel.requestIdrFrame()
        // One wake for the RFI edge, one for the IDR edge, none for the repeats.
        #expect(channel.recoveryWake.wait(timeout: .now()) == .success)
        #expect(channel.recoveryWake.wait(timeout: .now()) == .success)
        #expect(channel.recoveryWake.wait(timeout: .now()) == .timedOut)
    }

    @Test func repeatRfiWaitsOutTheSpacingThenSends() throws {
        let (channel, _) = try Self.makeChannel()
        let spacing = EnetControlChannel.recoveryMinSpacingMs
        channel.invalidateReferenceFrames(from: 10, to: 12)
        #expect(channel.drainPendingRecoveryRequests() == EnetControlChannel.controlTickMs)
        #expect(Self.urgentRelSeq(channel) == 1)

        // A second loss inside the spacing is held, and the loop wakes when it's due.
        channel.invalidateReferenceFrames(from: 13, to: 14)
        channel.lastRfiSentMs = channel.serviceTimeMs
        let wait = channel.drainPendingRecoveryRequests()
        #expect(wait >= 1 && wait <= spacing)
        #expect(Self.urgentRelSeq(channel) == 1)

        channel.lastRfiSentMs = channel.serviceTimeMs &- spacing
        #expect(channel.drainPendingRecoveryRequests() == EnetControlChannel.controlTickMs)
        #expect(Self.urgentRelSeq(channel) == 2)
    }

    @Test func repeatIdrWaitsOutTheSpacingThenSends() throws {
        let (channel, _) = try Self.makeChannel()
        let spacing = EnetControlChannel.recoveryMinSpacingMs
        channel.requestIdrFrame()
        #expect(channel.drainPendingRecoveryRequests() == EnetControlChannel.controlTickMs)
        #expect(Self.urgentRelSeq(channel) == 1)

        // The next failed frame's IDR inside the spacing is held until it's due.
        channel.requestIdrFrame()
        channel.lastIdrSentMs = channel.serviceTimeMs
        let wait = channel.drainPendingRecoveryRequests()
        #expect(wait >= 1 && wait <= spacing)
        #expect(Self.urgentRelSeq(channel) == 1)

        channel.lastIdrSentMs = channel.serviceTimeMs &- spacing
        #expect(channel.drainPendingRecoveryRequests() == EnetControlChannel.controlTickMs)
        #expect(Self.urgentRelSeq(channel) == 2)
    }

    @Test func idrLeavesAtOnceAndSupersedesAHeldRfi() throws {
        let (channel, _) = try Self.makeChannel()
        channel.invalidateReferenceFrames(from: 10, to: 12)
        _ = channel.drainPendingRecoveryRequests()
        channel.invalidateReferenceFrames(from: 13, to: 14)
        channel.lastRfiSentMs = channel.serviceTimeMs
        _ = channel.drainPendingRecoveryRequests() // held by the spacing
        channel.requestIdrFrame()
        #expect(channel.drainPendingRecoveryRequests() == EnetControlChannel.controlTickMs)
        #expect(Self.urgentRelSeq(channel) == 2)
        #expect(channel.withState { channel.pendingRfi == nil })
    }

    // MARK: - Cancel never strands the connect

    @Test func interruptBeforeOpenSocketThrowsInterrupted() async throws {
        let (channel, _) = try Self.makeChannel()
        channel.interrupt()
        do {
            try await channel.openSocket()
            Issue.record("openSocket succeeded after interrupt()")
        } catch EnetError.interrupted {
        } catch {
            Issue.record("expected EnetError.interrupted, got \(error)")
        }
    }

    // MARK: - Reliable delivery is in order and never wedges

    private final class Events {
        var values: [UInt16] = []
    }

    private static func rumble(_ value: UInt16, seq: UInt32) throws -> [UInt8] {
        var payload = ByteWriter()
        payload.u32LE(0)
        payload.append([0, 0, UInt8(truncatingIfNeeded: value), UInt8(value >> 8), 0, 0])
        return try StreamCryptoTests.sealHostDirection(
            type: CtrlV2.rumbleData, payload: payload.bytes, seq: seq, key: key)
    }

    @Test func reliableDeliveryPreservesCrossMessageOrder() throws {
        let (channel, _) = try Self.makeChannel()
        let events = Events()
        channel.onRumble = { _, low, _ in events.values.append(low) }
        channel.onRumbleTriggers = { _, left, right in
            #expect(left == 0 && right == 0)
            events.values.append(2)
        }
        let third = try Self.rumble(3, seq: 3)
        let off = try StreamCryptoTests.sealHostDirection(
            type: CtrlV2.rumbleTriggers, payload: [0, 0, 0, 0, 0, 0], seq: 2, key: Self.key)
        channel.onDatagram(Self.reliable(relSeq: 1, try Self.rumble(1, seq: 1)))
        channel.onDatagram(Self.reliable(relSeq: 3, third))
        #expect(events.values == [1])
        channel.onDatagram(Self.reliable(relSeq: 2, off))
        channel.onDatagram(Self.reliable(relSeq: 3, third))
        #expect(events.values == [1, 2, 3])
    }

    @Test func channelsKeepIndependentOrderAndFragmentsTakeNoTurn() throws {
        let (channel, _) = try Self.makeChannel()
        let events = Events()
        channel.onRumble = { _, low, _ in events.values.append(low) }
        channel.onDatagram(Self.reliable(relSeq: 2, try Self.rumble(2, seq: 2)))
        channel.onDatagram(Self.reliable(relSeq: 1, try Self.rumble(7, seq: 7), channel: 7))
        #expect(events.values == [7])
        channel.onDatagram([0, 0] + Self.prefix(Enet.cmdSendFragment))
        #expect(events.values == [7])
        channel.onDatagram(Self.reliable(relSeq: 1, try Self.rumble(1, seq: 1)))
        #expect(events.values == [7, 1, 2])
    }

    @Test func forgedExpectedReliableDoesNotAdvanceOrder() throws {
        let (channel, codes) = try Self.makeChannel()
        channel.onDatagram(Self.reliable(relSeq: 1, [1, 0] + [UInt8](repeating: 0xAB, count: 30)))
        channel.onDatagram(Self.reliable(relSeq: 1, try Self.termination(seq: 1)))
        #expect(codes.values == [Self.hostCode])
    }

    @Test func expiredGapReleasesOnAnyDatagram() throws {
        let (channel, _) = try Self.makeChannel()
        let events = Events()
        channel.onRumble = { _, low, _ in events.values.append(low) }
        channel.onDatagram(Self.reliable(relSeq: 1, try Self.rumble(1, seq: 1)))
        channel.onDatagram(Self.reliable(relSeq: 3, try Self.rumble(3, seq: 3)))
        #expect(events.values == [1])
        let now = channel.serviceTimeMs
        channel.inboundOrder[0]?.gapStartedMs = now &- (EnetInboundOrder.maxGapMs + 1)
        channel.onDatagram([0, 0])
        #expect(events.values == [1, 3])
    }

    @Test func missingReliableArrivingAfterGapExpiryKeepsOrder() throws {
        let (channel, _) = try Self.makeChannel()
        let events = Events()
        channel.onRumble = { _, low, _ in events.values.append(low) }
        channel.onDatagram(Self.reliable(relSeq: 1, try Self.rumble(1, seq: 1)))
        channel.onDatagram(Self.reliable(relSeq: 3, try Self.rumble(3, seq: 3)))
        #expect(events.values == [1])
        let now = channel.serviceTimeMs
        channel.inboundOrder[0]?.gapStartedMs = now &- (EnetInboundOrder.maxGapMs + 1)
        channel.onDatagram(Self.reliable(relSeq: 2, try Self.rumble(2, seq: 2)))
        #expect(events.values == [1, 2, 3])
    }

    @Test func fullGapReleasesHeldMessagesInOrder() throws {
        let (channel, _) = try Self.makeChannel()
        let events = Events()
        channel.onRumble = { _, low, _ in events.values.append(low) }
        for seq in (2...UInt16(EnetInboundOrder.maxHeld + 1)).reversed() {
            channel.onDatagram(Self.reliable(relSeq: seq, try Self.rumble(seq, seq: UInt32(seq))))
        }
        #expect(events.values == Array(2...UInt16(EnetInboundOrder.maxHeld + 1)))
        #expect(channel.inboundOrder[0]?.held.isEmpty == true)
    }

    @Test func inboundOrderHandlesGapsDuplicatesAndWrap() {
        var order = EnetInboundOrder()
        #expect(order.accept(1, payload: [1], nowMs: 10).due == [[1]])
        #expect(order.isDuplicate(1))
        #expect(order.accept(3, payload: [3], nowMs: 20).due.isEmpty)
        #expect(order.isDuplicate(3))
        #expect(!order.isDuplicate(2))
        #expect(order.accept(2, payload: [2], nowMs: 30).due == [[2], [3]])
        order.next = 0xFFFF
        #expect(order.accept(0, payload: [0], nowMs: 40).due.isEmpty)
        #expect(order.accept(0xFFFF, payload: [255], nowMs: 50).due == [[255], [0]])
        #expect(order.next == 1)
        #expect(order.isDuplicate(0xFFFF))
    }

    @Test func fullOrderSkipsOnlyTheMissingRange() {
        var order = EnetInboundOrder()
        for seq in 3..<UInt16(EnetInboundOrder.maxHeld + 2) {
            let result = order.accept(seq, payload: [], nowMs: 10)
            #expect(result.due.isEmpty && result.skipped == 0)
        }
        let result = order.accept(UInt16(EnetInboundOrder.maxHeld + 2), payload: [], nowMs: 10)
        #expect(result.skipped == 2)
        #expect(result.due == [[UInt8]](repeating: [], count: EnetInboundOrder.maxHeld))
        #expect(order.held.isEmpty)
        #expect(order.next == UInt16(EnetInboundOrder.maxHeld + 3))
    }

    @Test func gapClockRestartsAfterAnAdvanceAndWraps() {
        var order = EnetInboundOrder()
        _ = order.accept(3, payload: [3], nowMs: UInt32.max - 500)
        _ = order.accept(5, payload: [5], nowMs: UInt32.max - 400)
        #expect(order.releaseStaleGap(nowMs: 499).due.isEmpty)
        let first = order.releaseStaleGap(nowMs: 500)
        #expect(first.due == [[3]] && first.skipped == 2)
        #expect(order.gapStartedMs == 500)
        #expect(order.releaseStaleGap(nowMs: 1500).due.isEmpty)
        let second = order.releaseStaleGap(nowMs: 1501)
        #expect(second.due == [[5]] && second.skipped == 1)
    }

    // MARK: - Coalesced commands keep their framing

    private static func prefix(_ command: UInt8, relSeq: UInt16 = 1) -> [UInt8] {
        var body = ByteWriter()
        switch command {
        case Enet.cmdSendUnreliable, Enet.cmdSendUnsequenced, Enet.cmdSendFragment,
             Enet.cmdSendUnreliableFragment:
            body.u16BE(1)
            body.u16BE(3)
            if command == Enet.cmdSendFragment || command == Enet.cmdSendUnreliableFragment {
                body.append([UInt8](repeating: 0, count: 16))
            }
            body.append([7, 8, 9])
        case Enet.cmdBandwidthLimit: body.append([UInt8](repeating: 0, count: 8))
        case Enet.cmdThrottleConfigure: body.append([UInt8](repeating: 0, count: 12))
        default: break
        }
        return [command, 0, UInt8(relSeq >> 8), UInt8(truncatingIfNeeded: relSeq)] + body.bytes
    }

    @Test(arguments: [Enet.cmdSendUnreliable, Enet.cmdSendUnsequenced, Enet.cmdSendFragment,
                      Enet.cmdSendUnreliableFragment, Enet.cmdBandwidthLimit,
                      Enet.cmdThrottleConfigure, Enet.cmdPing])
    func skippedCommandPreservesFollowingTermination(command: UInt8) throws {
        let (channel, codes) = try Self.makeChannel()
        let datagram = Self.reliable(relSeq: 1, try Self.termination(seq: 1))
        channel.onDatagram(Array(datagram[..<4]) + Self.prefix(command) + datagram[4...])
        #expect(codes.values == [Self.hostCode])
    }

    @Test func everyTruncationRecoversOnNextDatagram() throws {
        let valid = Self.reliable(relSeq: 1, try Self.termination(seq: 2))
        let first = Self.reliable(relSeq: 1, try Self.termination(seq: 1))
        let prefixed = Array(first[..<4]) + Self.prefix(Enet.cmdSendUnreliable) + first[4...]
        for cut in 0..<prefixed.count {
            let (channel, codes) = try Self.makeChannel()
            channel.onDatagram(Array(prefixed.prefix(cut)))
            #expect(codes.values.isEmpty)
            channel.onDatagram(valid)
            #expect(codes.values == [Self.hostCode])
        }
    }

    // MARK: - The ACK clock never wraps

    @Test func futureAckDoesNotDeclarePeerDead() throws {
        let (channel, codes) = try Self.makeChannel()
        var state = channel.startControlLoop()
        channel.withState { channel.lastAckRecvMs = channel.serviceTimeMs &+ 5 }
        #expect(channel.controlLoopTick(&state))
        #expect(codes.values.isEmpty)
        #expect(channel.health().sinceLastAckMs < EnetControlChannel.ackSilenceDeadMs)
    }

    @Test func elapsedMillisecondsHandleClockOrdering() {
        #expect(EnetControlChannel.msSince(10, now: 20) == 10)
        #expect(EnetControlChannel.msSince(10, now: 10) == 0)
        #expect(EnetControlChannel.msSince(20, now: 10) == 0)
        #expect(EnetControlChannel.msSince(UInt32.max - 4, now: 5) == 10)
        #expect(EnetControlChannel.msSince(0, now: 0x8000_0000) == 0)
    }

    @Test(arguments: [UInt32(0x30), 1])
    func motionSequenceRolloverSendsReliably(negotiatedCount: UInt32) throws {
        let (channel, _) = try Self.makeChannel()
        let sensor = Enet.ctrlChannelSensorBase
        let effective = Enet.effectiveChannel(sensor, negotiatedCount: negotiatedCount)
        let motion = InputEncoder.controllerMotion(
            num: 0, motionType: UInt8(StreamProtocol.LI_MOTION_TYPE_GYRO), x: 1, y: 2, z: 3)
        channel.withState {
            channel.negotiatedChannelCount = negotiatedCount
            channel.channelOutgoingUnreliableSeq[effective] = 0xFFFE
        }

        #expect(channel.sendInputPacketUnreliable(motion, channel: sensor))
        channel.withState {
            #expect(channel.channelOutgoingReliableSeq[effective] == nil)
            #expect(channel.channelOutgoingUnreliableSeq[effective] == 0xFFFF)
            #expect(channel.sentReliable.isEmpty)
        }

        #expect(channel.sendInputPacketUnreliable(motion, channel: sensor))
        channel.withState {
            #expect(channel.channelOutgoingReliableSeq[effective] == 1)
            #expect(channel.channelOutgoingUnreliableSeq[effective] == 0)
            #expect(channel.sentReliable.count == 1)
            #expect(channel.sentReliable.first?.channelID == effective)
            #expect(channel.sentReliable.first?.reliableSequenceNumber == 1)
        }

        #expect(channel.sendInputPacketUnreliable(motion, channel: sensor))
        channel.withState {
            #expect(channel.channelOutgoingReliableSeq[effective] == 1)
            #expect(channel.channelOutgoingUnreliableSeq[effective] == 1)
            #expect(channel.sentReliable.count == 1)
        }
    }

    // MARK: - RTT stamps

    @Test func unreliableMotionDoesNotRecordRtt() throws {
        let (channel, _) = try Self.makeChannel()
        try channel.sendEncryptedControlUnreliable(type: CtrlV2.inputData, payload: [0],
                                                  channel: Enet.ctrlChannelSensorBase, label: "motion")
        #expect(channel.withState { channel.localSentByToken.isEmpty })
    }

    // MARK: - HDR metadata

    private static func hdrPayload(_ luminance: UInt16) -> [UInt8] {
        var payload = [UInt8](repeating: 0, count: 27)
        payload[0] = 1
        payload[17] = UInt8(truncatingIfNeeded: luminance)
        payload[18] = UInt8(luminance >> 8)
        return payload
    }

    @Test func hdrMetadataChangesNotifyWithoutModeChange() throws {
        let (channel, _) = try Self.makeChannel()
        let events = Events()
        channel.onHdrMode = { [weak channel] enabled in
            #expect(enabled)
            events.values.append(channel?.hdrMetadata()?.maxDisplayLuminance ?? 0)
        }
        channel.handleHdrInfo(Self.hdrPayload(1000))
        channel.handleHdrInfo(Self.hdrPayload(2000))
        channel.handleHdrInfo(Self.hdrPayload(2000))
        #expect(events.values == [1000, 2000])
    }

    // MARK: - ACKs reach the PC

    /// All callback-shared storage is guarded by lock; connections stay alive
    /// until teardown so UDP receives cannot disappear during the assertions.
    private final class AckCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var connections: [NWConnection] = []
        private var datagrams: [[UInt8]] = []
        private var port: UInt16?

        func setPort(_ value: UInt16?) { lock.lock(); port = value; lock.unlock() }
        func readyPort() -> UInt16? { lock.lock(); defer { lock.unlock() }; return port }
        func snapshot() -> [[UInt8]] { lock.lock(); defer { lock.unlock() }; return datagrams }
        func keep(_ connection: NWConnection) {
            lock.lock(); connections.append(connection); lock.unlock()
        }
        func cancelAll() {
            lock.lock()
            let accepted = connections
            connections.removeAll()
            lock.unlock()
            for connection in accepted { connection.cancel() }
        }
        func receive(_ connection: NWConnection) {
            connection.receiveMessage { [weak self] data, _, _, error in
                guard let self else { return }
                if let data {
                    self.lock.lock()
                    self.datagrams.append(Array(data))
                    self.lock.unlock()
                }
                if error == nil { self.receive(connection) }
            }
        }
    }

    private static func expectAck(_ bytes: [UInt8], channel: UInt8, seq: UInt16, sentTime: UInt16) {
        var reader = ByteReader(bytes)
        let header = reader.u16BE() ?? 0
        #expect(header & Enet.headerFlagSentTime != 0)
        if header & Enet.headerFlagSentTime != 0 { _ = reader.u16BE() }
        #expect(reader.u8() == Enet.cmdAcknowledge)
        #expect(reader.u8() == channel)
        #expect(reader.u16BE() == seq)
        #expect(reader.u16BE() == seq)
        #expect(reader.u16BE() == sentTime)
        #expect(reader.remaining == 0)
    }

    @Test func reliableAcknowledgementsReachThePeer() async throws {
        let listener = try NWListener(using: .udp, on: .any)
        let collector = AckCollector()
        let queue = DispatchQueue(label: "EnetControlChannelTests.listener")
        listener.stateUpdateHandler = { [weak listener] state in
            if case .ready = state { collector.setPort(listener?.port?.rawValue) }
        }
        listener.newConnectionHandler = { connection in
            collector.keep(connection)
            connection.start(queue: queue)
            collector.receive(connection)
        }
        listener.start(queue: queue)
        defer { listener.cancel(); collector.cancelAll() }
        for _ in 0..<200 {
            if collector.readyPort() != nil { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let port = try #require(collector.readyPort())
        let channel = EnetControlChannel(host: "127.0.0.1", port: port, controlConnectData: 0,
                                         crypto: try ControlCrypto(rikey: Self.key))
        defer { channel.close() }
        let openTimeout = Task {
            try await Task.sleep(for: .seconds(2))
            channel.interrupt()
        }
        defer { openTimeout.cancel() }
        try await channel.openSocket()
        openTimeout.cancel()
        let events = Events()
        channel.onRumble = { _, low, _ in events.values.append(low) }
        let first = Self.reliable(relSeq: 1, try Self.rumble(1, seq: 1), channel: 7, sentTime: 0x1234)
        channel.onDatagram(first)
        channel.onDatagram(first)
        channel.onDatagram(Self.reliable(relSeq: 3, try Self.rumble(3, seq: 3), channel: 7, sentTime: 0x1234))
        #expect(events.values == [1])
        channel.onDatagram(Self.reliable(relSeq: 2, try Self.rumble(2, seq: 2), channel: 7, hasSentTime: false))
        for _ in 0..<200 {
            if collector.snapshot().count >= 4 { break }
            try await Task.sleep(for: .milliseconds(10))
        }
        let packets = collector.snapshot()
        try #require(packets.count == 4)
        for (packet, seq) in zip(packets, [UInt16(1), 1, 3, 2]) {
            Self.expectAck(packet, channel: 7, seq: seq, sentTime: seq == 2 ? 0 : 0x1234)
        }
        #expect(events.values == [1, 2, 3])
    }
}
