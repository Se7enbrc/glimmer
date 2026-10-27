// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
#if canImport(GlimmerEngine)
@testable import GlimmerEngine
#else
@testable import Glimmer
#endif

extension CleanRoomProbe {
    struct AudioInput: Codable, Sendable {
        struct Step: Codable, Sendable {
            let packet: String?
            let conceal: Bool
        }
        let rate: Int32
        let channels: Int
        let streams: Int
        let coupled: Int
        let mapping: [UInt8]
        let samplesPerFrame: Int
        let steps: [Step]
    }

    // Every 16th frame of every channel as Int16, plus whole-interval RMS per channel.
    struct AudioStep: Codable, Equatable, Sendable {
        let frames: Int
        let overrun: Bool
        let rms: [Double]
        let samples: [Int16]
    }

    struct AudioOutput: Codable, Equatable, Sendable {
        let created: Bool
        let steps: [AudioStep]
    }

    static let audioStride = 16
    private static let sentinel: Float = 7

    static let audio = area("audio") { (input: AudioInput) -> AudioOutput in observeAudio(input) }

    static func observeAudio(_ input: AudioInput) -> AudioOutput {
        guard let decoder = OpusDecoder(sampleRate: input.rate, channels: input.channels, streams: input.streams,
                                        coupledStreams: input.coupled, mapping: input.mapping,
                                        samplesPerFrame: input.samplesPerFrame) else {
            return AudioOutput(created: false, steps: [])
        }
        let width = input.channels
        let capacity = input.samplesPerFrame * width
        var steps: [AudioStep] = []
        for step in input.steps {
            // Twice the negotiated capacity, so a write past it shows up as an overrun.
            var pcm = [Float](repeating: sentinel, count: capacity * 2)
            let packet = step.packet.flatMap { Data(base64Encoded: $0) }
            let frames = pcm.withUnsafeMutableBufferPointer { output -> Int in
                guard let base = output.baseAddress else { return -1 }
                guard let packet else { return decoder.decode(nil, into: base) }
                return packet.withUnsafeBytes {
                    step.conceal ? decoder.decodeOrConceal($0, into: base) : decoder.decode($0, into: base)
                }
            }
            let used = max(0, min(frames, input.samplesPerFrame * 2)) * width
            let overrun = pcm[min(used, pcm.count)...].contains { $0 != sentinel } || frames > input.samplesPerFrame
            var rms = [Double](repeating: 0, count: width)
            var samples: [Int16] = []
            for frame in 0..<(used / max(width, 1)) {
                for channel in 0..<width {
                    let value = Double(pcm[frame * width + channel])
                    rms[channel] += value * value
                    if frame % audioStride == 0 {
                        samples.append(Int16(max(-32_768, min(32_767, (value * 32_767).rounded()))))
                    }
                }
            }
            let count = Double(max(frames, 1))
            steps.append(AudioStep(frames: frames, overrun: overrun,
                                   rms: rms.map { ($0 / count).squareRoot() }, samples: samples))
        }
        return AudioOutput(created: true, steps: steps)
    }
}
