// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import Testing
@testable import GlimmerEngine

@Suite(.serialized)
struct SurroundDecodeTests {
    struct Layout: Sendable {
        let channels: Int
        let coupled: Int
        let mapping: [UInt8]
        var streams: Int { channels - coupled }
    }

    static let layouts = [
        Layout(channels: 1, coupled: 0, mapping: [0]),
        Layout(channels: 2, coupled: 1, mapping: [0, 1]),
        Layout(channels: 6, coupled: 2, mapping: [0, 4, 1, 5, 2, 3]),
        Layout(channels: 8, coupled: 3, mapping: [0, 6, 1, 7, 2, 3, 4, 5]),
        Layout(channels: 6, coupled: 0, mapping: Array(0...5)),
        Layout(channels: 8, coupled: 0, mapping: Array(0...7))
    ]

    private func decoder(_ layout: Layout, capacity: Int = 240,
                         failure: ((Int) -> Bool)? = nil) throws -> OpusDecoder {
        let adjustment: ((Int, Int?) -> Int?)? = failure.map { failure in
            { index, count in failure(index) ? nil : count }
        }
        return try #require(OpusDecoder(sampleRate: 48_000, channels: layout.mapping.count,
                                streams: layout.streams, coupledStreams: layout.coupled,
                                mapping: layout.mapping, samplesPerFrame: capacity, conversionResult: adjustment))
    }

    private func packet(_ layout: Layout, number: Int) -> Data {
        var bytes = Data()
        for stream in 0..<layout.streams {
            let lane = stream < layout.coupled ? 8 + stream : stream + layout.coupled
            let coded = SurroundToneData.packets(lane: lane)[number]
            if stream < layout.streams - 1 {
                bytes.append(coded[0])
                let length = coded.count - 1
                if length < 252 { bytes.append(UInt8(length)) } else {
                    bytes.append(UInt8(252 + length % 4))
                    bytes.append(UInt8((length - 252) / 4))
                }
                bytes.append(coded.dropFirst())
            } else { bytes.append(coded) }
        }
        return bytes
    }

    private func decode(_ decoder: OpusDecoder, _ data: Data?, _ pcm: inout [Float], conceal: Bool = false) -> Int {
        pcm.withUnsafeMutableBufferPointer { destination in
            guard let output = destination.baseAddress else { return 0 }
            guard let data else { return decoder.decode(nil, into: output) }
            return data.withUnsafeBytes {
                conceal ? decoder.decodeOrConceal($0, into: output) : decoder.decode($0, into: output)
            }
        }
    }

    @Test(arguments: layouts)
    func eachSpeakerRetainsItsFrequency(_ layout: Layout) throws {
        let session = try decoder(layout)
        var pcm = [Float](repeating: 0, count: 240 * layout.channels)
        #expect(decode(session, nil, &pcm) == 0)
        var collected = [[Float]](repeating: [], count: layout.channels)
        for number in 0..<16 {
            let count = decode(session, packet(layout, number: number), &pcm)
            #expect(number == 0 ? count > 0 && count <= 240 : count == 240)
            if number >= 4 {
                for channel in 0..<layout.channels {
                    collected[channel].append(contentsOf: (0..<count).map { pcm[$0 * layout.channels + channel] })
                }
            }
        }
        for destination in 0..<layout.channels {
            let scores = (0..<layout.channels).map { spectralPower(collected[destination], channel: $0) }
            #expect(scores.indices.max(by: { scores[$0] < scores[$1] }) == Int(layout.mapping[destination]))
        }
        for _ in 0..<3 { #expect(decode(session, nil, &pcm) == 240) }
        #expect(decode(session, packet(layout, number: 15), &pcm) == 240)
    }

    private func spectralPower(_ samples: [Float], channel: Int) -> Double {
        let radians = 2 * Double.pi * Double(400 + 200 * channel) / 48_000
        var real = 0.0
        var imaginary = 0.0
        for (index, sample) in samples.enumerated() {
            real += Double(sample) * cos(radians * Double(index))
            imaginary += Double(sample) * sin(radians * Double(index))
        }
        return real * real + imaginary * imaginary
    }

    @Test func negotiatedDuplicatesAndSilenceUseExactSamples() throws {
        let source = Layout(channels: 2, coupled: 1, mapping: [0, 1])
        let remapped = Layout(channels: 2, coupled: 1, mapping: [1, 255, 0, 1])
        let normal = try decoder(source)
        let routed = try decoder(remapped)
        var original = [Float](repeating: 0, count: 480)
        var changed = [Float](repeating: 9, count: 960)
        for number in 0..<8 {
            let bytes = packet(source, number: number)
            let frames = decode(normal, bytes, &original)
            #expect(decode(routed, bytes, &changed) == frames)
            for frame in 0..<frames {
                #expect(changed[frame * 4] == original[frame * 2 + 1])
                #expect(changed[frame * 4 + 1] == 0)
                #expect(changed[frame * 4 + 2] == original[frame * 2])
                #expect(changed[frame * 4 + 3] == changed[frame * 4])
            }
        }
    }

    @Test func rejectedTailLeavesEveryCodecUntouched() throws {
        let layout = Self.layouts[3]
        let subject = try decoder(layout)
        let reference = try decoder(layout)
        var actual = [Float](repeating: 0, count: 1_920)
        var expected = actual
        for number in 0..<4 {
            let data = packet(layout, number: number)
            #expect(decode(subject, data, &actual) == decode(reference, data, &expected))
        }
        var invalid = packet(layout, number: 4)
        invalid.removeLast(SurroundToneData.packets(lane: 7)[4].count)
        invalid.append(3) // Code 3 without its mandatory count field.
        #expect(decode(subject, invalid, &actual) == 0)
        #expect(decode(subject, packet(layout, number: 5), &actual) == 240)
        #expect(decode(reference, packet(layout, number: 5), &expected) == 240)
        #expect(actual == expected)
    }

    @Test func failedInputConcealsAndCountsOncePerPacket() throws {
        let layout = Self.layouts[2]
        let session = try decoder(layout)
        var pcm = [Float](repeating: 0, count: 1_440)
        _ = decode(session, packet(layout, number: 0), &pcm)
        #if os(macOS) || GLIMMER_DIAGNOSTICS
        let before = TelemetryCounters.shared.audioDecodeFailedTotal.value
        #endif
        for _ in 0..<3 { #expect(decode(session, Data(), &pcm, conceal: true) == 240) }
        #if os(macOS) || GLIMMER_DIAGNOSTICS
        #expect(TelemetryCounters.shared.audioDecodeFailedTotal.value == before + 3)
        #endif
        #expect(decode(session, packet(layout, number: 1), &pcm) == 240)
    }

    @Test func partialPlatformFailureRetiresAllLaneHistories() throws {
        let layout = Self.layouts[2]
        var shouldFail = false
        let subject = try decoder(layout, failure: { shouldFail && $0 == 1 })
        var pcm = [Float](repeating: 0, count: 1_440)
        _ = decode(subject, packet(layout, number: 0), &pcm)
        shouldFail = true
        #expect(decode(subject, packet(layout, number: 1), &pcm, conceal: true) == 240)
        shouldFail = false
        let restarted = try decoder(layout)
        var reference = [Float](repeating: 0, count: 1_440)
        let frames = decode(subject, packet(layout, number: 2), &pcm)
        let referenceFrames = decode(restarted, packet(layout, number: 2), &reference)
        #expect(frames == 240)
        #expect(Array(pcm[(frames - referenceFrames) * 6..<frames * 6])
                == Array(reference.prefix(referenceFrames * 6)))
        #expect(decode(subject, packet(layout, number: 3), &pcm) == 240)
        for channel in 0..<6 { #expect((0..<240).contains { abs(pcm[$0 * 6 + channel]) > 0.001 }) }
    }

    @Test(arguments: [0, 60])
    func laneStartupDifferencesAlignAtThePacketEnd(shortened: Int) throws {
        let layout = Layout(channels: 2, coupled: 0, mapping: [0, 1])
        var starting = true
        let subject = try #require(OpusDecoder(sampleRate: 48_000, channels: 2, streams: 2,
            coupledStreams: 0, mapping: [0, 1], samplesPerFrame: 240,
            conversionResult: { index, frames in starting && index == 1 ? shortened : frames }))
        let reference = try decoder(layout)
        var actual = [Float](repeating: 0, count: 480)
        var expected = actual
        let frames = decode(subject, packet(layout, number: 0), &actual)
        let native = decode(reference, packet(layout, number: 0), &expected)
        #expect(frames == shortened)
        #expect(Array(actual.prefix(frames * 2)) == Array(expected[(native - frames) * 2..<native * 2]))
        starting = false
        #expect(decode(subject, packet(layout, number: 1), &actual) == 240)
        #expect(decode(reference, packet(layout, number: 1), &expected) == 240)
        #expect(actual == expected)
        #expect(decode(subject, nil, &actual) == 240)
    }

    @Test func mismatchedDurationsAndCapacityRejectionDoNotPublish() throws {
        let layout = Layout(channels: 2, coupled: 0, mapping: [0, 1])
        let session = try decoder(layout)
        var bytes = packet(layout, number: 0)
        let tail = SurroundToneData.packets(lane: 1)[0].count
        bytes[bytes.count - tail] ^= 8
        var pcm = [Float](repeating: 37, count: 480)
        #expect(decode(session, bytes, &pcm) == 0)
        #expect(pcm.allSatisfy { $0 == 37 })
        let tooSmall = try decoder(layout, capacity: 120)
        #expect(decode(tooSmall, packet(layout, number: 0), &pcm) == 0)
        #expect(decode(tooSmall, nil, &pcm) == 0)
        #expect(pcm.allSatisfy { $0 == 37 })
    }

    @Test func multiFramePacketsConcealTheNegotiatedInterval() throws {
        let layout = Self.layouts[0]
        let session = try decoder(layout, capacity: 480)
        let singles = SurroundToneData.packets(lane: 0)
        var pcm = [Float](repeating: 0, count: 480)
        for number in 0..<6 {
            let first = singles[number * 2]
            let second = singles[number * 2 + 1]
            let length = first.count - 1
            var combined = Data([first[0] | 2])
            if length < 252 { combined.append(UInt8(length)) } else {
                combined.append(UInt8(252 + length % 4))
                combined.append(UInt8((length - 252) / 4))
            }
            combined.append(first.dropFirst())
            combined.append(second.dropFirst())
            let frames = decode(session, combined, &pcm)
            #expect(number == 0 ? frames > 0 : frames == 480)
        }
        for _ in 0..<3 { #expect(decode(session, nil, &pcm) == 480) }
    }

    @Test func repeatedSessionsDoNotShareHistoryOrOverwriteCapacity() throws {
        for layout in Self.layouts {
            for _ in 0..<12 {
                let session = try decoder(layout)
                var pcm = [Float](repeating: 71, count: 240 * layout.channels + 16)
                #expect(decode(session, nil, &pcm) == 0)
                _ = decode(session, packet(layout, number: 0), &pcm)
                #expect(decode(session, packet(layout, number: 1), &pcm) == 240)
                #expect(pcm.suffix(16).allSatisfy { $0 == 71 })
            }
        }
    }

    @Test func impossibleConfigurationsFailBeforeAllocation() {
        for capacity in [0, -1, Int.max, 5_761] {
            #expect(OpusDecoder(sampleRate: 48_000, channels: 2, streams: 1, coupledStreams: 1,
                                mapping: [0, 1], samplesPerFrame: capacity) == nil)
        }
        for mapping in [[], [0], [0, 2], [254, 0]] as [[UInt8]] {
            #expect(OpusDecoder(sampleRate: 48_000, channels: 2, streams: 1, coupledStreams: 1,
                                mapping: mapping, samplesPerFrame: 240) == nil)
        }
        for streams in [-1, 0, 9, Int.max] {
            #expect(OpusDecoder(sampleRate: 48_000, channels: 2, streams: streams, coupledStreams: 1,
                                mapping: [0, 1], samplesPerFrame: 240) == nil)
        }
    }
}

struct OpusEnvelopeTests {
    private func inspect(_ bytes: [UInt8], delimited: Bool = false) -> OpusEnvelope? {
        bytes.withUnsafeBytes { OpusEnvelope.inspect($0, from: 0, delimited: delimited) }
    }

    // Synthetic framing only: RFC 6716 section 3/Appendix B; payloads are not codec fixtures.
    @Test func allPackingModesHaveIndependentBoundaries() throws {
        let cases: [(bytes: [UInt8], duration: Int, delimiter: Range<Int>)] = [
            ([0x80, 0], 120, 1..<2),
            ([0x81, 1, 17, 18], 240, 1..<2),
            ([0x82, 1, 2, 17, 18, 19], 240, 2..<3),
            ([0x83, 3, 1, 17, 18, 19], 360, 2..<3),
            ([0x83, 0x83, 0, 1, 2, 17, 18, 19], 360, 4..<5),
            ([0x83, 0x42, 2, 1, 17, 18, 0, 0], 240, 3..<4)
        ]
        for item in cases {
            let parsed = try #require(inspect(item.bytes + [0xFF, 0xFF], delimited: true))
            #expect(parsed.consumed == item.bytes.count)
            #expect(parsed.duration48k == item.duration)
            #expect(parsed.delimiter == item.delimiter)
            let ordinary = Array(item.bytes[..<item.delimiter.lowerBound] + item.bytes[item.delimiter.upperBound...])
            #expect(inspect(ordinary)?.duration48k == item.duration)
        }
    }

    @Test func lengthsPaddingAndTruncationStayBounded() {
        for size in [0, 1, 251, 252, 255, 256, 1_275] {
            let length = size < 252 ? [UInt8(size)] : [UInt8(252 + size % 4), UInt8((size - 252) / 4)]
            let bytes = [UInt8(0x88)] + length + Array(repeating: UInt8(93), count: size)
            #expect(inspect(bytes, delimited: true)?.consumed == bytes.count)
            for end in 0..<bytes.count { #expect(inspect(Array(bytes.prefix(end)), delimited: true) == nil) }
        }
        #expect(inspect([0x83, 0x41, 255, 1, 0] + Array(repeating: 0, count: 255))?.duration48k == 120)
        for bytes in [[], [3], [3, 0], [0x83, 49], [0x81, 1], [0x82, 252],
                               [0x83, 0x41, 255], [0] + Array(repeating: 1, count: 1_276),
                               Array(repeating: 0, count: 10_209)] as [[UInt8]] {
            #expect(inspect(bytes) == nil)
        }
    }
}
