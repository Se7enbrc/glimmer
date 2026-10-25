// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Darwin

enum SocketTimestamp {
    static let millisecondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) / 1_000_000
    }()
}

#if os(macOS) || GLIMMER_DIAGNOSTICS

extension SocketTimestamp {
    static let controlSize = 64

    @discardableResult
    static func enable(on socket: Int32) -> Bool {
        var enabled: Int32 = 1
        return setsockopt(socket, SOL_SOCKET, SO_TIMESTAMP_MONOTONIC,
                          &enabled, socklen_t(MemoryLayout<Int32>.size)) == 0
    }

    // Darwin aligns ancillary records to four bytes, including their UInt64 payloads.
    static func arrival(in control: UnsafeRawPointer?, length: Int, flags: Int32) -> UInt64? {
        guard let control, flags & MSG_CTRUNC == 0, length <= controlSize else { return nil }
        let headerSize = MemoryLayout<cmsghdr>.size
        var offset = 0
        while offset + headerSize <= length {
            let header = control.loadUnaligned(fromByteOffset: offset, as: cmsghdr.self)
            let size = Int(header.cmsg_len)
            guard size >= headerSize, size <= length - offset else { return nil }
            if header.cmsg_level == SOL_SOCKET, header.cmsg_type == SCM_TIMESTAMP_MONOTONIC {
                guard size >= headerSize + MemoryLayout<UInt64>.size else { return nil }
                let ticks = control.loadUnaligned(fromByteOffset: offset + headerSize, as: UInt64.self)
                return ticks > 0 ? ticks : nil
            }
            offset += (size + 3) & ~3
        }
        return nil
    }
}

#endif
