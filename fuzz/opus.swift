// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

@testable import GlimmerEngine

//
//  opus.swift
//
//  Opus packet framing (RFC 6716 section 3 and Appendix B), which splits the PC's
//  surround packets into one packet per stream.
//

/// The first byte picks where parsing starts and whether the packet is self-delimited.
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzOpus(_ data: UnsafePointer<UInt8>, _ size: Int) -> CInt {
    guard size > 0 else { return 0 }
    let packet = UnsafeRawBufferPointer(start: data + 1, count: size - 1)
    let start = Int(data[0] & 0x7F)
    if let parsed = OpusEnvelope.inspect(packet, from: start, delimited: data[0] & 0x80 != 0) {
        precondition(parsed.consumed <= packet.count && parsed.delimiter.upperBound <= parsed.consumed)
        precondition((1...5_760).contains(parsed.duration48k))
    }
    return 0
}
