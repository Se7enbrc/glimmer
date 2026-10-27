// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AVFoundation
import os

// AudioDecoder serializes this session's codec and scratch storage under its state lock.
final class OpusDecoder {
    let channels: Int
    let samplesPerFrame: Int
    private let rate: Int
    private let routes: [UInt8]
    private let lanes: [NativeOpusLane]
    private var envelopes: [OpusEnvelope]
    private var previous: [Float]
    private var previousFrames = 0
    private var recovering = false
    private var reportedFailure = false
    private var acceptedPriming = false
    private let conversionResult: ((Int, Int?) -> Int?)?
    private let log = Logger(subsystem: "io.ugfugl.Glimmer", category: "OpusDecoder")

    init?(sampleRate: Int32, channels: Int, streams: Int, coupledStreams: Int,
          mapping: [UInt8], samplesPerFrame: Int, conversionResult: ((Int, Int?) -> Int?)? = nil) {
        guard [8_000, 12_000, 16_000, 24_000, 48_000].contains(sampleRate),
              (1...8).contains(channels), (1...8).contains(streams),
              (0...streams).contains(coupledStreams), mapping.count == channels,
              samplesPerFrame > 0, samplesPerFrame <= Int(sampleRate) * 120 / 1_000,
              mapping.allSatisfy({ $0 == 255 || Int($0) < streams + coupledStreams }) else { return nil }
        var prepared: [NativeOpusLane] = []
        for index in 0..<streams {
            guard let lane = NativeOpusLane(rate: sampleRate, width: index < coupledStreams ? 2 : 1,
                                            capacity: samplesPerFrame) else { return nil }
            prepared.append(lane)
        }
        self.channels = channels
        self.samplesPerFrame = samplesPerFrame
        self.conversionResult = conversionResult
        rate = Int(sampleRate)
        routes = mapping
        lanes = prepared
        envelopes = Array(repeating: OpusEnvelope(consumed: 0, delimiter: 0..<0, duration48k: 0), count: streams)
        previous = Array(repeating: 0, count: samplesPerFrame * channels)
    }

    func decode(_ packet: UnsafeRawBufferPointer?, into pcm: UnsafeMutablePointer<Float>) -> Int {
        acceptedPriming = false
        if packet == nil {
            guard previousFrames > 0 else { return 0 }
            if recovering { return bridgeLoss(into: pcm) }
        }
        let frames: Int
        if let packet {
            guard let duration = validate(packet) else { return 0 }
            frames = duration
        } else {
            frames = lanes[0].framesPerPacket
        }
        var start = 0
        var common = frames
        for (index, lane) in lanes.enumerated() {
            let envelope = envelopes[index]
            let end = packet == nil ? 0 : envelope.consumed
            let field = packet == nil ? 0..<0 : envelope.delimiter
            let native = lane.convert(packet, span: start..<end, removing: field, frames: frames)
            let result: Int?
            if let conversionResult { result = conversionResult(index, native) } else { result = native }
            guard let result, result >= 0, result <= frames,
                  result <= Int(lane.output.frameLength), lane.output.floatChannelData != nil else {
                // Apple exposes no codec-history rollback. Reset every lane together after a partial failure.
                for lane in lanes { lane.reset() }
                recovering = true
                return 0
            }
            common = min(common, result)
            start = end
        }
        if common > 0 { publish(frames: common, into: pcm) }
        acceptedPriming = common == 0 && packet != nil
        recovering = false
        return common
    }

    func decodeOrConceal(_ packet: UnsafeRawBufferPointer?, into pcm: UnsafeMutablePointer<Float>) -> Int {
        let result = decode(packet, into: pcm)
        guard packet != nil, result == 0, !acceptedPriming else { return result }
        #if os(macOS)
        TelemetryCounters.shared.audioDecodeFailedTotal.increment()
        #endif
        if !reportedFailure {
            reportedFailure = true
            log.notice("An audio packet could not be decoded; concealing the missing interval")
        }
        return decode(nil, into: pcm)
    }

    private func validate(_ packet: UnsafeRawBufferPointer) -> Int? {
        var start = 0
        var duration = 0
        for index in lanes.indices {
            guard let envelope = OpusEnvelope.inspect(packet, from: start, delimited: index < lanes.count - 1),
                  index == 0 || duration == envelope.duration48k else { return nil }
            envelopes[index] = envelope
            duration = envelope.duration48k
            start = envelope.consumed
        }
        let frames = duration * rate / 48_000
        guard start == packet.count, frames <= samplesPerFrame else { return nil }
        return frames
    }

    private func publish(frames: Int, into pcm: UnsafeMutablePointer<Float>) {
        var decodedChannel = 0
        for lane in lanes {
            guard let source = lane.output.floatChannelData?[0] else { continue }
            let offset = Int(lane.output.frameLength) - frames
            for channel in 0..<lane.width {
                for destination in routes.indices where Int(routes[destination]) == decodedChannel + channel {
                    for frame in 0..<frames {
                        pcm[frame * channels + destination] = source[(frame + offset) * lane.width + channel]
                    }
                }
            }
            decodedChannel += lane.width
        }
        for destination in routes.indices where routes[destination] == 255 {
            for frame in 0..<frames { pcm[frame * channels + destination] = 0 }
        }
        previous.withUnsafeMutableBufferPointer { $0.baseAddress?.update(from: pcm, count: frames * channels) }
        previousFrames = frames
    }

    // A failed converter has no PLC history. Bridge one negotiated interval with a fading last interval.
    private func bridgeLoss(into pcm: UnsafeMutablePointer<Float>) -> Int {
        for frame in 0..<samplesPerFrame {
            let gain = 1 - Float(frame + 1) / Float(samplesPerFrame)
            for channel in 0..<channels {
                pcm[frame * channels + channel] = previous[(frame % previousFrames) * channels + channel] * gain
            }
        }
        previous.withUnsafeMutableBufferPointer { $0.baseAddress?.update(from: pcm, count: samplesPerFrame * channels) }
        previousFrames = samplesPerFrame
        return samplesPerFrame
    }
}
