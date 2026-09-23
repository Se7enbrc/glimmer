//
//  EnetControlChannelTests.swift
//
//  Drives EnetControlChannel through its inbound parser, control-loop tick and
//  recovery drain with no live socket: every send drops on the nil connection,
//  so the observable effects are the callbacks and the channel's own state.
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

    /// One SENT_TIME datagram carrying a SEND_RELIABLE on the generic channel.
    private static func reliable(relSeq: UInt16, _ payload: [UInt8]) -> [UInt8] {
        var w = ByteWriter()
        w.u16BE(Enet.headerFlagSentTime)
        w.u16BE(0)
        w.u8(Enet.cmdSendReliable | Enet.flagAcknowledge)
        w.u8(Enet.ctrlChannelGeneric)
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
}
