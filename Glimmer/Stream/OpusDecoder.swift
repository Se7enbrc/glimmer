// Sunshine surround packets contain separately framed mono/stereo Opus streams.
// AudioToolbox decodes each stream; the negotiated mapping restores PC channel order.

import Foundation

/// One session's Opus decoder. AudioDecoder holds its state lock throughout decoding and teardown.
final class OpusDecoder {
    private struct Channel {
        let output: Int
        let input: Int
    }

    let channels: Int
    let samplesPerFrame: Int
    private let decoders: [OpusStreamDecoder]
    private let routes: [[Channel]]
    private let mutedChannels: [Int]
    private let sampleRate: Int
    private let scratch: UnsafeMutablePointer<Float>?
    private var packets: [OpusPacket?]
    private var hasReceivedPacket = false

    static let maxPacketBytes = 8 * 1_276

    init?(sampleRate: Int32, channels: Int, streams: Int, coupledStreams: Int,
          mapping: [UInt8], samplesPerFrame: Int) {
        guard sampleRate > 0, (1...8).contains(channels), mapping.count == channels, (1...8).contains(streams),
              (0...streams).contains(coupledStreams), samplesPerFrame > 0,
              mapping.allSatisfy({ $0 == 255 || Int($0) < streams + coupledStreams }) else { return nil }
        var decoders: [OpusStreamDecoder] = []
        decoders.reserveCapacity(streams)
        for index in 0..<streams {
            guard let decoder = OpusStreamDecoder(sampleRate: sampleRate, channels: index < coupledStreams ? 2 : 1,
                                                  samplesPerFrame: samplesPerFrame) else { return nil }
            decoders.append(decoder)
        }
        self.channels = channels
        self.samplesPerFrame = samplesPerFrame
        self.sampleRate = Int(sampleRate)
        self.decoders = decoders
        routes = (0..<streams).map { stream in
            let first = stream < coupledStreams ? 2 * stream : stream + coupledStreams
            let count = decoders[stream].channels
            return mapping.enumerated().compactMap { output, value -> Channel? in
                let input = Int(value) - first
                return (0..<count).contains(input) ? Channel(output: output, input: input) : nil
            }
        }
        mutedChannels = mapping.indices.filter { mapping[$0] == 255 }
        packets = Array(repeating: nil, count: streams)
        let direct = streams == 1 && channels == streams + coupledStreams
            && mapping.enumerated().allSatisfy { Int($0.element) == $0.offset }
        scratch = direct ? nil : .allocate(capacity: samplesPerFrame * 2)
    }

    deinit {
        scratch?.deallocate()
    }

    /// Writes interleaved PCM, trimming initial lookahead once. Nil conceals one lost packet;
    /// loss before the first packet produces no samples.
    func decode(_ packet: UnsafeRawBufferPointer?, into pcm: UnsafeMutablePointer<Float>) -> Int {
        if let packet {
            guard !packet.isEmpty, packet.count <= Self.maxPacketBytes, parse(packet) else { return 0 }
            if !hasReceivedPacket { Diag.info("Opus on AudioToolbox, \(Self.mode(packet[0])) frames", "Stream.Audio") }
            hasReceivedPacket = true
        } else if !hasReceivedPacket {
            return 0
        }
        guard let scratch else {
            return decoders[0].decode(packet, start: 0, boundary: packets[0], into: pcm)
        }
        var start = 0
        var frames: Int?
        var valid = true
        for (index, decoder) in decoders.enumerated() {
            let decoded = decoder.decode(packet, start: start, boundary: packets[index], into: scratch)
            if let frames { valid = valid && decoded == frames } else { frames = decoded }
            copyChannels(from: scratch, stream: index, frames: decoded, into: pcm)
            start = packets[index]?.end ?? 0
        }
        guard valid, let frames, frames > 0 else { return 0 }
        for channel in mutedChannels {
            for frame in 0..<frames { pcm[frame * channels + channel] = 0 }
        }
        return frames
    }

    private func parse(_ packet: UnsafeRawBufferPointer) -> Bool {
        var start = 0
        var samples: Int?
        // Validate every stream before advancing any decoder, so a truncated tail cannot desynchronise them.
        for index in decoders.indices {
            guard let boundary = OpusPacket.parse(packet, at: start, selfDelimited: index < decoders.count - 1),
                  boundary.samplesAt48kHz * sampleRate <= samplesPerFrame * 48_000 else { return false }
            if let samples, samples != boundary.samplesAt48kHz { return false }
            samples = boundary.samplesAt48kHz
            packets[index] = boundary
            start = boundary.end
        }
        return start == packet.count
    }

    private func copyChannels(from source: UnsafeMutablePointer<Float>, stream: Int, frames: Int,
                              into pcm: UnsafeMutablePointer<Float>) {
        let count = decoders[stream].channels
        for channel in routes[stream] {
            for frame in 0..<frames {
                pcm[frame * channels + channel.output] = source[frame * count + channel.input]
            }
        }
    }

    private static func mode(_ toc: UInt8) -> String {
        switch toc >> 3 {
        case 0..<12: "SILK"
        case 12..<16: "hybrid"
        default: "CELT"
        }
    }
}
