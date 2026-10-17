// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

// What the decode and prime paths hand the player, recorded through `schedulePlayout`:
// buffer order, frame counts, zeroed backfill silence and the cushion target behind it.

@testable import GlimmerEngine
import AVFAudio
import Foundation
import Testing
@testable import Glimmer

@Suite(.serialized)
struct AudioPlayoutScheduleTests {

    /// One real 5 ms stereo CELT packet at Sunshine's settings (from OpusDecoderTests).
    private static let packet = "ec7f4bd60777985d8731b747622a18fd2b679a2e9def04904278899d9136b906038d671fa4e046bc58abc93cb740be"
        + "2bcd584efccd910bf0cff90084"

    /// Unchecked: every schedule in these tests runs on the test's own thread.
    private final class Recorder: @unchecked Sendable {
        struct Entry { let frames: Int; let silent: Bool; let complete: @Sendable () -> Void }
        var entries: [Entry] = []

        func record(_ buffer: AVAudioPCMBuffer, _: Bool, _ complete: @escaping @Sendable () -> Void) {
            let frames = Int(buffer.frameLength)
            let channels = (0..<Int(buffer.format.channelCount)).compactMap { buffer.floatChannelData?[$0] }
            let silent = channels.allSatisfy { channel in (0..<frames).allSatisfy { channel[$0] == 0 } }
            entries.append(Entry(frames: frames, silent: silent, complete: complete))
        }
    }

    /// A decoder whose player is the recorder. The prime edge is pinned shut so no engine starts.
    private func harness() throws -> (AudioDecoder, Recorder, AVAudioFormat) {
        let decoder = AudioDecoder()
        let recorder = Recorder()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        decoder.schedulePlayout = recorder.record
        decoder.decoder = OpusDecoder(sampleRate: 48_000, channels: 2, streams: 1, coupledStreams: 1,
                                      mapping: [0, 1], samplesPerFrame: 240)
        decoder.inputFormat = format
        decoder.preparePCMStorage(format: format)
        decoder.primeEdgeRetryAtNanos = .max
        return (decoder, recorder, format)
    }

    private func frames(ms: Double) -> Int { Int(AVAudioFrameCount(ms / 1000 * 48_000)) }

    @Test func drainReprimesThenBackfillsTheDeficitBehindDecodedAudio() throws {
        let (decoder, recorder, _) = try harness()
        defer { decoder.shutdown() }
        let packet = try #require(Data(hex: Self.packet))
        packet.withUnsafeBytes { decoder.decodeAndPlay($0) }
        let first = try #require(recorder.entries.first)
        #expect(recorder.entries.count == 1 && first.frames > 0 && !first.silent)
        #expect(decoder.framesScheduled == UInt64(first.frames))

        // Playback ran and drained: the next packet re-arms a re-prime and grows the target a step.
        decoder.primed = true
        first.complete()
        decoder.meterCompleteOnePlayout(frames: UInt64(first.frames), confirmedUnderrun: true)
        #expect(decoder.playoutDrained)
        decoder.decodeAndPlayPLC()
        #expect(recorder.entries.map(\.frames).dropFirst() == [240])
        #expect(decoder.rebuildIsReprime && !decoder.primed)
        #expect(decoder.playoutTargetMs == AudioDecoder.playoutCushionBaseMs + AudioDecoder.playoutCushionStepMs)

        // Inside the grace nothing is padded; once it lapses the deficit follows the packet as silence.
        decoder.gateGraceUntilNanos = 0
        decoder.decodeAndPlayPLC()
        let tail = recorder.entries.suffix(2)
        let aheadMs = Double(2 * 240) / 48_000 * 1000
        #expect(tail.map(\.frames) == [240, frames(ms: decoder.playoutTargetMs - aheadMs)])
        #expect(tail.map(\.silent) == [false, true])
        #expect(decoder.pendingSilenceFrames == UInt64(frames(ms: decoder.playoutTargetMs - aheadMs)))
        tail.last?.complete()
        decoder.meterCompleteOnePlayout(frames: UInt64(tail.last?.frames ?? 0), isSilence: true)
        #expect(decoder.pendingSilenceFrames == 0)
    }

    @Test func resolveTopUpPadsOnceToTheAdoptedTarget() throws {
        let (decoder, recorder, format) = try harness()
        defer { decoder.shutdown() }
        decoder.stateLock.lock()
        defer { decoder.stateLock.unlock() }
        decoder.primed = true
        decoder.playoutTargetMs = 100
        decoder.framesScheduled = UInt64(frames(ms: 20))
        decoder.pendingResolveTopUp = true
        decoder.maybePrime(format: format)
        decoder.maybePrime(format: format)
        #expect(recorder.entries.map(\.frames) == [frames(ms: 80)])
        #expect(recorder.entries.allSatisfy { $0.silent })
        #expect(!decoder.pendingResolveTopUp)
    }

    @Test func subStepDeficitPrimesWithoutPadding() throws {
        let (decoder, recorder, format) = try harness()
        defer { decoder.shutdown() }
        decoder.stateLock.lock()
        defer { decoder.stateLock.unlock() }
        decoder.rebuildIsReprime = true
        decoder.playoutTargetMs = 40
        decoder.framesScheduled = UInt64(frames(ms: 40 - AudioDecoder.playoutCushionStepMs / 2))
        decoder.maybePrime(format: format)
        #expect(recorder.entries.isEmpty)
    }

    @Test func steadyTrimSchedulesNothing() throws {
        let (decoder, recorder, _) = try harness()
        defer { decoder.shutdown() }
        decoder.primed = true
        decoder.playoutStarted = true
        decoder.playoutTargetMs = 40
        decoder.framesScheduled = UInt64(frames(ms: 120))
        let packet = try #require(Data(hex: Self.packet))
        packet.withUnsafeBytes { decoder.decodeAndPlay($0) }
        #expect(recorder.entries.isEmpty)
        #expect(decoder.framesScheduled == UInt64(frames(ms: 120)))
    }
}
