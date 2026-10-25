// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

final class OpusDecoder {
    let channels: Int
    let samplesPerFrame: Int

    init?(sampleRate: Int32, channels: Int, streams: Int, coupledStreams: Int,
          mapping: [UInt8], samplesPerFrame: Int) {
        fatalError("clean-room: replace per spec-1")
    }

    func decode(_ packet: UnsafeRawBufferPointer?, into pcm: UnsafeMutablePointer<Float>) -> Int {
        fatalError("clean-room: replace per spec-1")
    }

    func decodeOrConceal(_ packet: UnsafeRawBufferPointer?, into pcm: UnsafeMutablePointer<Float>) -> Int {
        fatalError("clean-room: replace per spec-1")
    }
}
