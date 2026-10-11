// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  LoopbackUdpPeer.swift
//
//  A UDP socket on 127.0.0.1 standing in for the PC. It replies to wherever the
//  client's datagram came from, as Sunshine does, so receivers keep their ephemeral port.
//

import Darwin
import Foundation
import os
@testable import Glimmer

final class LoopbackUdpPeer: Sendable {
    let fd: Int32
    let port: UInt16

    init?() {
        let fd = socket(AF_INET, SOCK_DGRAM, 0)
        guard fd >= 0 else { return nil }
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, len) == 0 && getsockname(fd, $0, &len) == 0
            }
        }
        guard bound else { close(fd); return nil }
        self.fd = fd
        self.port = UInt16(bigEndian: addr.sin_port)
    }

    deinit { close(fd) }

    /// The next datagram and its sender, or nil when none arrives within `timeout`.
    func receive(within timeout: Duration) -> (bytes: [UInt8], from: sockaddr_in)? {
        var pending = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pending, 1, Int32(timeout / .milliseconds(1))) == 1 else { return nil }
        var buffer = [UInt8](repeating: 0, count: 2048)
        var source = sockaddr_in()
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let count = withUnsafeMutablePointer(to: &source) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                recvfrom(fd, &buffer, buffer.count, 0, $0, &length)
            }
        }
        guard count >= 0 else { return nil }
        return (Array(buffer.prefix(count)), source)
    }

    func send(_ bytes: [UInt8], to destination: sockaddr_in) {
        var destination = destination
        _ = withUnsafePointer(to: &destination) { ptr in
            ptr.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(fd, bytes, bytes.count, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
    }
}

/// Just enough of Sunshine's ENet side: VERIFY_CONNECT for a CONNECT, an ACK for every
/// acknowledged command, and a record of each reliable payload. Runs on its own thread.
final class EnetLoopbackPeer: Sendable {
    struct Reliable: Equatable {
        let channel: UInt8, relSeq: UInt16, data: [UInt8]
    }

    /// The peer ID the client must adopt from VERIFY_CONNECT.
    static let assignedPeerID: UInt16 = 7

    let udp: LoopbackUdpPeer
    /// Echoing a different connectID forges the VERIFY_CONNECT, which the client must refuse.
    private let forgesConnectID: Bool
    private let state = OSAllocatedUnfairLock(initialState: (reliables: [Reliable](), connectData: UInt32?.none))
    /// Signalled once per newly recorded reliable command.
    let reliableArrived = DispatchSemaphore(value: 0)
    private let stopped = ManagedAtomicFlag()
    private let finished = DispatchSemaphore(value: 0)

    init?(forgesConnectID: Bool = false) {
        guard let udp = LoopbackUdpPeer() else { return nil }
        self.udp = udp
        self.forgesConnectID = forgesConnectID
        let thread = Thread { [self] in
            serve()
            finished.signal()
        }
        // The test waits on this thread, so it runs at the test's QoS to avoid an inversion.
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    var reliables: [Reliable] { state.withLock { $0.reliables } }
    var connectData: UInt32? { state.withLock { $0.connectData } }

    /// Ends the serving thread; bounded so a wedged peer cannot hang the suite.
    func stop() {
        stopped.set()
        _ = finished.wait(timeout: .now() + 5)
    }

    private func serve() {
        let deadline = ContinuousClock.now + .seconds(30)
        while !stopped.isSet, ContinuousClock.now < deadline {
            guard let (bytes, from) = udp.receive(within: .milliseconds(20)) else { continue }
            let replies = answer(bytes)
            if !replies.isEmpty { udp.send(EnetFixture.datagram(replies, sentTime: 0x0101), to: from) }
        }
    }

    private func answer(_ bytes: [UInt8]) -> [[UInt8]] {
        var reader = ByteReader(bytes)
        guard let header = reader.u16BE() else { return [] }
        let sentTime = header & Enet.headerFlagSentTime != 0 ? reader.u16BE() ?? 0 : 0
        var replies: [[UInt8]] = []
        while let byte = reader.u8(), let channel = reader.u8(), let relSeq = reader.u16BE() {
            guard let reply = consume(byte & Enet.commandMask, channel: channel, relSeq: relSeq,
                                      reader: &reader) else { break }
            replies += reply
            if byte & Enet.flagAcknowledge != 0 {
                replies.append(EnetFixture.ack(channel: channel, relSeq: relSeq, sentTime: sentTime))
            }
        }
        return replies
    }

    /// Reads one command's body; nil for a command this peer can't size.
    private func consume(_ command: UInt8, channel: UInt8, relSeq: UInt16,
                         reader: inout ByteReader) -> [[UInt8]]? {
        switch command {
        case Enet.cmdConnect:
            guard let body = reader.take(44) else { return nil }
            state.withLock { $0.connectData = UInt32(body[40]) << 24 | UInt32(body[41]) << 16
                | UInt32(body[42]) << 8 | UInt32(body[43]) }
            return [verifyConnect(connectID: Array(body[36..<40]))]
        case Enet.cmdSendReliable:
            guard let length = reader.u16BE(), let data = reader.take(Int(length)) else { return nil }
            let reliable = Reliable(channel: channel, relSeq: relSeq, data: data)
            let isNew = state.withLock { recorded in
                guard !recorded.reliables.contains(reliable) else { return false }
                recorded.reliables.append(reliable)
                return true
            }
            if isNew { reliableArrived.signal() }
        case Enet.cmdSendUnreliable:
            guard reader.take(2) != nil, let length = reader.u16BE(), reader.take(Int(length)) != nil else { return nil }
        case Enet.cmdAcknowledge:
            guard reader.take(4) != nil else { return nil }
        case Enet.cmdPing:
            break
        default:
            return nil
        }
        return []
    }

    private func verifyConnect(connectID: [UInt8]) -> [UInt8] {
        var w = ByteWriter()
        w.u8(Enet.cmdVerifyConnect | Enet.flagAcknowledge)
        w.u8(Enet.peerChannelID)
        w.u16BE(1)
        w.u16BE(Self.assignedPeerID)
        w.u8(0)
        w.u8(0)
        for value in [Enet.defaultMTU, Enet.maximumWindowSize, Enet.ctrlChannelCount, 0, 0,
                      Enet.packetThrottleInterval, Enet.packetThrottleAcceleration, Enet.packetThrottleDeceleration] {
            w.u32BE(value)
        }
        w.append(forgesConnectID ? connectID.map { $0 ^ 0xFF } : connectID)
        return w.bytes
    }
}
