// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Loopback tests pin the Darwin record layout and keep payloads, peer addresses and timestamps paired.

@testable import GlimmerEngine
import Darwin
import Foundation
import Testing
@testable import Glimmer

struct DatagramBatchTests {

    /// xnu's msghdr_x on arm64: pointers at 0, 16 and 32, the 32-bit fields after each, the length at 48.
    @Test func recordMatchesTheKernelLayout() {
        typealias Record = DatagramBatch.Record
        #expect(MemoryLayout<Record>.size == 56)
        #expect(MemoryLayout<Record>.stride == 56)
        #expect(MemoryLayout<Record>.offset(of: \.name) == 0)
        #expect(MemoryLayout<Record>.offset(of: \.nameLength) == 8)
        #expect(MemoryLayout<Record>.offset(of: \.iov) == 16)
        #expect(MemoryLayout<Record>.offset(of: \.iovCount) == 24)
        #expect(MemoryLayout<Record>.offset(of: \.control) == 32)
        #expect(MemoryLayout<Record>.offset(of: \.controlLength) == 40)
        #expect(MemoryLayout<Record>.offset(of: \.flags) == 44)
        #expect(MemoryLayout<Record>.offset(of: \.dataLength) == 48)
    }

    /// Each receive path preserves payloads and reports the sender's address independently of its port.
    @Test(arguments: [true, false], [true, false])
    func receivesQueuedDatagrams(batched: Bool, timestamped: Bool) throws {
        let receiver = socket(AF_INET, SOCK_DGRAM, 0)
        let sender = socket(AF_INET, SOCK_DGRAM, 0)
        defer { close(receiver); close(sender) }
        var address = sockaddr_in()
        address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(receiver, $0, length) == 0 && getsockname(receiver, $0, &length) == 0
            }
        }
        try #require(bound)
        var timeout = timeval(tv_sec: 1, tv_usec: 0)
        setsockopt(receiver, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        if timestamped { try #require(SocketTimestamp.enable(on: receiver)) }
        let before = mach_absolute_time()
        let sizes = [0, 1, 64, 300, 1392, 17]
        for (index, size) in sizes.enumerated() {
            let payload = [UInt8](repeating: UInt8(index + 1), count: size)
            let sent = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(sender, payload, size, 0, $0, length) }
            }
            try #require(sent == size)
        }
        // Loopback delivers on its own thread: wait until all packets are queued, or a busy machine
        // hands the one call only the first few.
        try #require(waitForQueuedDatagrams(Int32(sizes.count), on: receiver))

        let queuedAt = mach_absolute_time()
        let batch = DatagramBatch(capacity: 32, stride: 1500, receiveBatch: MacTransport.receiveBatch)
        let expected = try #require(UdpPinger.makeSockaddr(for: .init("127.0.0.1"), port: 1))
        let other = try #require(UdpPinger.makeSockaddr(for: .init("127.0.0.2"), port: 1))
        if batched { #expect(batch.receive(from: receiver) == sizes.count) }
        for (index, size) in sizes.enumerated() {
            if !batched { #expect(batch.receiveOne(from: receiver) == 1) }
            let slot = batched ? index : 0
            #expect(batch.readStartedTicks >= queuedAt)
            #expect(batch.readTicks >= batch.readStartedTicks)
            #expect(batch.previousReadTicks <= batch.readStartedTicks)
            #expect(batch.isExpectedPeer(at: slot, expected: expected.0, expectedLength: expected.1))
            #expect(!batch.isExpectedPeer(at: slot, expected: other.0, expectedLength: other.1))
            if timestamped {
                let arrival = try #require(batch.arrivalTicks(at: slot))
                #expect(arrival >= before && arrival <= queuedAt && queuedAt <= batch.readTicks)
            } else {
                #expect(batch.arrivalTicks(at: slot) == nil)
            }
            let datagram = batch.datagram(slot)
            #expect(datagram.length == size)
            let bytes = UnsafeBufferPointer(start: datagram.bytes, count: datagram.length)
            #expect(bytes.allSatisfy { $0 == UInt8(index + 1) })
        }
        try expectNoStaleTimestamp(batch, batched: batched, receiver: receiver, sender: sender, address: address)
    }

    private func expectNoStaleTimestamp(_ batch: DatagramBatch, batched: Bool, receiver: Int32,
                                        sender: Int32, address: sockaddr_in) throws {
        var disabled: Int32 = 0
        try #require(setsockopt(receiver, SOL_SOCKET, SO_TIMESTAMP_MONOTONIC, &disabled, 4) == 0)
        let payload: [UInt8] = [42]
        let sent = withUnsafePointer(to: address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                sendto(sender, payload, 1, 0, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try #require(sent == 1)
        let previousRead = batch.readTicks
        #expect((batched ? batch.receive(from: receiver) : batch.receiveOne(from: receiver)) == 1)
        #expect(batch.previousReadTicks == previousRead)
        #expect(batch.arrivalTicks(at: 0) == nil)
        #expect(batch.datagram(0).length == 1)
    }

    private func waitForQueuedDatagrams(_ count: Int32, on socket: Int32) -> Bool {
        let deadline = Date().addingTimeInterval(1)
        var queued: Int32 = 0
        var size = socklen_t(MemoryLayout<Int32>.size)
        while Date() < deadline {
            if getsockopt(socket, SOL_SOCKET, SO_NUMRCVPKT, &queued, &size) == 0, queued >= count { return true }
            usleep(1_000)
        }
        return false
    }
}
