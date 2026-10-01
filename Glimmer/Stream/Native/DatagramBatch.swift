//
//  DatagramBatch.swift
//
//  Batched UDP receive on Darwin's recvmsg_x: up to `capacity` datagrams per syscall, into buffers allocated
//  once. The system exports the call but the SDK declares neither it nor its record, so both are mirrored here.
//

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

    init(capacity: Int, stride: Int) {
        self.capacity = capacity
        self.stride = stride
        storage = .allocate(capacity: capacity * stride)
        iovecs = .allocate(capacity: capacity)
        records = .allocate(capacity: capacity)
        for index in 0..<capacity {
            (iovecs + index).initialize(to: iovec(iov_base: storage + index * stride, iov_len: stride))
        }
        records.initialize(repeating: Record(), count: capacity)
    }

    deinit {
        storage.deallocate()
        iovecs.deallocate()
        records.deallocate()
    }

    /// Reads up to `capacity` datagrams in one call: the count, or -1 with errno set (ENOSYS without recvmsg_x,
    /// EAGAIN on the socket's receive timeout, as recvfrom reports it).
    func receive(from socket: Int32) -> Int {
        guard let receiveX = Self.receiveX else {
            errno = ENOSYS
            return -1
        }
        for index in 0..<capacity { records[index] = Record(iov: iovecs + index, iovCount: 1) }
        return receiveX(socket, records, UInt32(capacity), 0)
    }

    /// Datagram `index` from the last receive, its length clamped to the stride so a misread can't run past it.
    func datagram(_ index: Int) -> (bytes: UnsafeMutablePointer<UInt8>, length: Int) {
        (storage + index * stride, min(records[index].dataLength, stride))
    }
}
