// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  video.swift
//
//  Video datagrams from the PC through RtpVideoQueue: RTP parsing, reordering,
//  Reed-Solomon recovery and the depacketizer's frame assembly.
//

private final class FrameSink: VideoDepacketizerDelegate {
    func depacketizerDidAssembleFrame(_ unit: DecodeUnit) {
        precondition(unit.fullLength >= 0 && Int(unit.fullLength) <= VideoDepacketizer.maxFrameBytes)
    }
    func depacketizerDetectedFrameLoss(from: Int, to: Int) {}
    func depacketizerNeedsIdr() {}
    func depacketizerReceivedKeyFrame(frameNumber: Int) {}
}

private let formats = [StreamProtocol.VIDEO_FORMAT_H264, StreamProtocol.VIDEO_FORMAT_H265,
                       StreamProtocol.VIDEO_FORMAT_AV1_MAIN8]

/// The first byte picks the codec and the negotiated packet size.
@_cdecl("LLVMFuzzerTestOneInput")
public func fuzzVideo(_ data: UnsafePointer<UInt8>, _ size: Int) -> CInt {
    guard size > 0 else { return 0 }
    let input = UnsafeRawBufferPointer(start: data, count: size)
    let sink = FrameSink()
    let depacketizer = VideoDepacketizer(delegate: sink, negotiatedVideoFormat: formats[Int(input[0]) % 3],
                                         colorSpace: 0)
    let queue = RtpVideoQueue(depacketizer: depacketizer, packetSize: input[0] & 0x80 == 0 ? 144 : 1_392)
    var clock: UInt64 = 1_000
    for datagram in datagrams(UnsafeRawBufferPointer(rebasing: input[1...])) {
        clock += datagram.stepUs
        queue.addRawDatagram(datagram.bytes, receiveTimeUs: clock)
    }
    return 0
}
