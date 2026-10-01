//
//  OpusDecoderTests.swift
//
//  AudioToolbox's Opus decoder on real packets: libopus-encoded 5 ms CELT at Sunshine's settings, one tone
//  per channel at -12 dBFS (RMS ~0.18), so silence, a stall or a dead channel all show.
//

import Foundation
import Testing
@testable import Glimmer

struct OpusDecoderTests {

    private static let stereo = [
        "ec7f4bd60777985d8731b747622a18fd2b679a2e9def04904278899d9136b906038d671fa4e046bc58abc93cb740be2bcd584efccd910bf0cff90084",
        "ecc8b89010be17d51a2b34d6852b3ac4d7c33ace08a21eff5aae3eacff7a34b6cea490b94b28ab226da7e91382d7128dc6f75c34000febc11f8a4b13",
        "ecc85e2a7260a98bd240544742674e73cd84b9044ca02a89b1192dcead05793df85afd62dd245bb923c409023199c4d690ba5136aaff474cc44d5312",
        "ecc8a90053eb7363cf9cb521719ab8d1788db26fb0e031265ccd726e45328df4bc90fe98addf0cedd7194fbba2b8b569425c90fb53d0b5d2514d0712",
        "ecc839e66ceabdc6e046c54aca71bbc4d5f381392fdbfc66cb1c45609162df8849385700a2c44561eb939851a40b578a91696969e9450b0fcddf6b12"
    ]

    private static let surround = [
        "ec317f4bd60777985d8731b747622a18fd2b58ba3e0057468ddd3732e3f92382a6590cbf5f174f9d47c1e3c1d28d842fffd044ec319fd4b5"
            + "93502f5b1414326a43ad3e59c5422a6f2bea5105ec8cc5544ec719abb94bb2d30ddf292990900ba68c52530d0a91e81d7e0124724f22854c"
            + "88e49d2652e2dd3f2905585239a73db649004c23bde87e4f6593f28af9160db0a92afd9a568435086428a6e3a40f0f83",
        "ec31c8b89010be17d51a2b345fed2a1849e43875866d8fb917594ca8a0ace631286e75e985afc9ec18be34570d002bc1e2d713ec319e7285"
            + "495c88266495ac16fd2d44a316ee271d1b0e697eeb7c01a383e3d86ef95865976771aaaac95aaeab40088cc333d2e81d9e6b2cbacda0a0fd"
            + "f4e83f340a14f69698e19f055f0e761df7003cc3e5e8880cff26d2f6e53c7e90a770af0588dd10a874108a8f402a007e",
        "ec31c85e2a7260a9956dc90ff5e330f05360127d4f9d338f20e7b07b9817c948a48213ee866361ffeee8aea416fd1f45139b12ec319e8327"
            + "c8fd131222e03e73f4522a871364d2f740bd0394b1311b57fea3f3c20fb702a05aaed7ac85c6ef16668fe70dd2d1e81d9d5ad8feccb55d64"
            + "46c2d07415dd37266a881cf26da17b5b760077b1e5e887cbc3fab1cc590788c64ae37f3fde3e7c06b5d0c86d404308fe"
    ]

    /// Sunshine's layouts, from its DESCRIBE surround-params once SdpScan has reordered them.
    private struct Layout {
        let channels: Int, streams: Int, coupled: Int, mapping: [UInt8]
    }

    private static let layouts = [
        Layout(channels: 2, streams: 1, coupled: 1, mapping: [0, 1]),
        Layout(channels: 6, streams: 4, coupled: 2, mapping: [0, 1, 2, 4, 5, 3]),
        Layout(channels: 6, streams: 6, coupled: 0, mapping: [0, 1, 2, 3, 4, 5]),
        Layout(channels: 8, streams: 5, coupled: 3, mapping: [0, 1, 2, 4, 5, 3, 6, 7]),
        Layout(channels: 8, streams: 8, coupled: 0, mapping: [0, 1, 2, 3, 4, 5, 6, 7])
    ]

    private static func decoder(channels: Int = 2, streams: Int = 1, coupled: Int = 1,
                                mapping: [UInt8] = [0, 1]) -> OpusDecoder? {
        OpusDecoder(sampleRate: 48_000, channels: channels, streams: streams, coupledStreams: coupled,
                    mapping: mapping, samplesPerFrame: 240)
    }

    /// Each packet's frames out and per-channel RMS; nil packets are losses.
    private static func run(_ decoder: OpusDecoder, _ hex: [String?]) -> [(frames: Int, rms: [Float])] {
        var pcm = [Float](repeating: 0, count: 240 * decoder.channels)
        return hex.map { hex in
            let frames = pcm.withUnsafeMutableBufferPointer { out -> Int in
                guard let base = out.baseAddress else { return 0 }
                guard let hex, let packet = Data(hex: hex) else { return decoder.decode(nil, into: base) }
                return packet.withUnsafeBytes { decoder.decode($0, into: base) }
            }
            let rms = (0..<decoder.channels).map { channel -> Float in
                guard frames > 0 else { return 0 }
                let samples = (0..<frames).map { pcm[$0 * decoder.channels + channel] }
                return (samples.reduce(0) { $0 + $1 * $1 } / Float(frames)).squareRoot()
            }
            return (frames, rms)
        }
    }

    @Test func opensEveryLayoutSunshineSends() {
        for layout in Self.layouts {
            #expect(Self.decoder(channels: layout.channels, streams: layout.streams, coupled: layout.coupled,
                                 mapping: layout.mapping) != nil, "\(layout)")
        }
    }

    @Test func refusesLayoutsOpusCannotDescribe() {
        #expect(OpusDecoder(sampleRate: 0, channels: 2, streams: 1, coupledStreams: 1, mapping: [0, 1],
                            samplesPerFrame: 240) == nil)
        #expect(Self.decoder(channels: 2, mapping: [0]) == nil)
        #expect(Self.decoder(streams: 0, coupled: 0) == nil)
        #expect(Self.decoder(streams: 1, coupled: 2) == nil)
        #expect(Self.decoder(channels: 9, streams: 9, coupled: 0, mapping: Array(0..<9)) == nil)
    }

    /// The encoder's 2.5 ms lookahead is trimmed once, from the first packet, and nothing is held back after.
    @Test func stereoTrimsTheLookaheadOnceThenKeepsPace() throws {
        let decoder = try #require(Self.decoder())
        let out = Self.run(decoder, Self.stereo)
        #expect(out.map(\.frames) == [120, 240, 240, 240, 240])
        for packet in out.dropFirst(2) { #expect(packet.rms.allSatisfy { $0 > 0.1 }, "\(packet.rms)") }
    }

    /// A zero-byte packet would end the stream and fade it out; the in-band lost packet conceals and recovers.
    @Test func lostPacketIsConcealedAndTheStreamRecovers() throws {
        let decoder = try #require(Self.decoder())
        let out = Self.run(decoder, [Self.stereo[0], Self.stereo[1], Self.stereo[2], nil, Self.stereo[3], Self.stereo[4]])
        #expect(out.map(\.frames) == [120, 240, 240, 240, 240, 240])
        #expect(out[3].rms.allSatisfy { $0 > 0.05 }, "concealed \(out[3].rms)")
        for packet in out.suffix(2) { #expect(packet.rms.allSatisfy { $0 > 0.1 }, "recovered \(packet.rms)") }
    }

    @Test func lossBeforeAnyPacketYieldsNothing() throws {
        let decoder = try #require(Self.decoder())
        #expect(Self.run(decoder, [nil]).map(\.frames) == [0])
    }

    @Test func surroundDecodesEveryChannel() throws {
        let decoder = try #require(Self.decoder(channels: 6, streams: 4, coupled: 2, mapping: [0, 1, 2, 4, 5, 3]))
        let out = Self.run(decoder, Self.surround)
        #expect(out.map(\.frames) == [120, 240, 240])
        #expect(out[2].rms.allSatisfy { $0 > 0.1 }, "\(out[2].rms)")
    }

    @Test func wireFormsMatchTheSpecs() {
        let rate: [UInt8] = [0x80, 0xBB, 0, 0]   // 48000 LE
        let head = Array("OpusHead".utf8)
        #expect(OpusDecoder.opusHead(sampleRate: 48_000, channels: 2, streams: 1, coupledStreams: 1, mapping: [0, 1])
            == head + [1, 2, 0, 0] + rate + [0, 0, 0])
        #expect(OpusDecoder.opusHead(sampleRate: 48_000, channels: 6, streams: 4, coupledStreams: 2,
                                     mapping: [0, 1, 2, 4, 5, 3])
            == head + [1, 6, 0, 0] + rate + [0, 0, 1, 4, 2, 0, 1, 2, 4, 5, 3])
        #expect(OpusDecoder.lostPacket(toc: 0xEC, streams: 4) == [0xEC, 0, 0xEC, 0, 0xEC, 0, 0xEC])
        #expect(OpusDecoder.lostPacket(toc: 0xEC, streams: 1) == [0xEC])
        #expect(OpusDecoder.mode(0xEC) == "CELT")
        #expect(OpusDecoder.mode(0x60) == "hybrid")
        #expect(OpusDecoder.mode(0x08) == "SILK")
    }
}
