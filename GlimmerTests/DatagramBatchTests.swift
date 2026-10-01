//
//  DatagramBatchTests.swift
//
//  The recvmsg_x record against xnu's layout, and a real batch off a loopback socket.
//

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

    /// Five queued datagrams come back from one call, each with its own length and bytes.
    @Test func receivesQueuedDatagramsInOneCall() throws {
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

        let sizes = [1, 64, 300, 1392, 17]
        for (index, size) in sizes.enumerated() {
            let payload = [UInt8](repeating: UInt8(index + 1), count: size)
            let sent = withUnsafePointer(to: &address) { pointer in
                pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { sendto(sender, payload, size, 0, $0, length) }
            }
            try #require(sent == size)
        }

        let batch = DatagramBatch(capacity: 32, stride: 1500)
        #expect(batch.receive(from: receiver) == sizes.count)
        for (index, size) in sizes.enumerated() {
            let datagram = batch.datagram(index)
            #expect(datagram.length == size)
            let bytes = UnsafeBufferPointer(start: datagram.bytes, count: datagram.length)
            #expect(bytes.allSatisfy { $0 == UInt8(index + 1) })
        }
    }
}
