// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// Batch storage is reused for payloads, addresses and kernel receive timestamps.

import Darwin

/// One receive loop's batch. Not thread-safe; the loop that owns it is its only caller.
final class DatagramBatch {
    /// xnu's `struct msghdr_x` (bsd/sys/socket.h), field for field; DatagramBatchTests pins every offset.
    struct Record {
        var name: UnsafeMutableRawPointer?
        var nameLength: socklen_t = 0
        var iov: UnsafeMutablePointer<iovec>?
        var iovCount: Int32 = 0
        var control: UnsafeMutableRawPointer?
        var controlLength: socklen_t = 0
        var flags: Int32 = 0
        var dataLength: Int = 0
    }

    private typealias ReceiveX = @convention(c) (Int32, UnsafeMutableRawPointer, UInt32, Int32) -> Int
    /// recvmsg_x from the default symbol scope (RTLD_DEFAULT is -2), or nil on a system without it.
    private static let receiveX: ReceiveX? = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "recvmsg_x")
        .map { unsafeBitCast($0, to: ReceiveX.self) }

    let capacity: Int
    let stride: Int
    let storage: UnsafeMutablePointer<UInt8>
    private let iovecs: UnsafeMutablePointer<iovec>
    private let records: UnsafeMutablePointer<Record>
    private let controls: UnsafeMutableRawPointer
    private(set) var readTicks: UInt64 = 0
    private let sources: UnsafeMutablePointer<sockaddr_storage>

    init(capacity: Int, stride: Int) {
        self.capacity = capacity
        self.stride = stride
        controls = .allocate(byteCount: capacity * SocketTimestamp.controlSize, alignment: 8)
        storage = .allocate(capacity: capacity * stride)
        iovecs = .allocate(capacity: capacity)
        records = .allocate(capacity: capacity)
        sources = .allocate(capacity: capacity)
        sources.initialize(repeating: sockaddr_storage(), count: capacity)
        for index in 0..<capacity {
            (iovecs + index).initialize(to: iovec(iov_base: storage + index * stride, iov_len: stride))
        }
        records.initialize(repeating: Record(), count: capacity)
    }

    deinit {
        controls.deallocate()
        storage.deallocate()
        iovecs.deallocate()
        records.deallocate()
        sources.deallocate()
    }

    /// Reads up to `capacity` datagrams in one call: the count, or -1 with errno set (ENOSYS without recvmsg_x,
    /// EAGAIN on the socket's receive timeout, as recvmsg reports it).
    func receive(from socket: Int32) -> Int {
        guard let receiveX = Self.receiveX else {
            errno = ENOSYS
            return -1
        }
        for index in 0..<capacity {
            records[index] = Record(name: sources + index,
                                    nameLength: socklen_t(MemoryLayout<sockaddr_storage>.size),
                                    iov: iovecs + index, iovCount: 1,
                                    control: controls + index * SocketTimestamp.controlSize,
                                    controlLength: socklen_t(SocketTimestamp.controlSize))
        }
        let count = receiveX(socket, records, UInt32(capacity), 0)
        readTicks = mach_absolute_time()
        return count
    }

    func receiveOne(from socket: Int32) -> Int {
        var message = msghdr(msg_name: sources,
                             msg_namelen: socklen_t(MemoryLayout<sockaddr_storage>.size),
                             msg_iov: iovecs, msg_iovlen: 1, msg_control: controls,
                             msg_controllen: socklen_t(SocketTimestamp.controlSize), msg_flags: 0)
        let count = recvmsg(socket, &message, 0)
        readTicks = mach_absolute_time()
        guard count >= 0 else { return -1 }
        records[0] = Record(name: sources, nameLength: message.msg_namelen,
                            control: controls, controlLength: message.msg_controllen,
                            flags: message.msg_flags, dataLength: count)
        return 1
    }

    func arrivalTicks(at index: Int) -> UInt64? {
        SocketTimestamp.arrival(in: records[index].control, length: Int(records[index].controlLength),
                                flags: records[index].flags)
    }

    func isExpectedPeer(at index: Int, expected: sockaddr_storage, expectedLength: socklen_t) -> Bool {
        UdpPinger.isExpectedPeer(sources[index], length: records[index].nameLength,
                                expected: expected, expectedLength: expectedLength)
    }

    /// Datagram `index` from the last receive, its length clamped to the stride so a misread can't run past it.
    func datagram(_ index: Int) -> (bytes: UnsafeMutablePointer<UInt8>, length: Int) {
        (storage + index * stride, min(records[index].dataLength, stride))
    }
}
