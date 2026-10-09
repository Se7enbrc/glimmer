import AVFoundation
import Testing
@testable import Glimmer

struct AudioPacketSpliceTests {
    private func buffer(channels: Int = 2, frames: Int = 240,
                        sample: (Int, Int) -> Float) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000,
                                               channels: AVAudioChannelCount(channels)))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)))
        pcm.frameLength = AVAudioFrameCount(frames)
        let data = try #require(pcm.floatChannelData)
        for channel in 0..<channels {
            for frame in 0..<frames { data[channel][frame] = sample(channel, frame) }
        }
        return pcm
    }

    @Test func trimSmoothsBothChannelsWithoutAddingLatency() throws {
        func tone(_ frame: Int) -> Float { sin(Float(frame) * 2 * .pi * 150 / 48_000) }
        let skipped = try buffer { channel, frame in tone(frame + 240) * (channel == 0 ? 1 : -1) }
        let next = try buffer { channel, frame in tone(frame + 480) * (channel == 0 ? 1 : -1) }
        var splice = AudioPacketSplice()
        splice.skip(skipped)
        splice.apply(to: next)
        let data = try #require(next.floatChannelData)
        for channel in 0..<2 {
            let sign: Float = channel == 0 ? 1 : -1
            var previous = tone(239) * sign
            var largestStep: Float = 0
            for frame in 0..<240 {
                largestStep = max(largestStep, abs(data[channel][frame] - previous))
                previous = data[channel][frame]
                if frame >= 47 { #expect(data[channel][frame] == tone(frame + 480) * sign) }
            }
            #expect(largestStep < 0.08)
        }
        #expect(next.frameLength == 240)
        #expect(!splice.hasPendingJoin)
    }

    @Test func uninterruptedAudioIsUnchanged() throws {
        let pcm = try buffer { channel, frame in Float(channel * 240 + frame) / 480 }
        var splice = AudioPacketSplice()
        splice.apply(to: pcm)
        let data = try #require(pcm.floatChannelData)
        for channel in 0..<2 {
            for frame in 0..<240 {
                #expect(data[channel][frame] == Float(channel * 240 + frame) / 480)
            }
        }
    }

    @Test func consecutiveDropsKeepTheOriginalBoundary() throws {
        var splice = AudioPacketSplice()
        splice.skip(try buffer { _, _ in 0.25 })
        splice.skip(try buffer { _, _ in -0.5 })
        let next = try buffer { _, _ in 0.75 }
        splice.apply(to: next)
        let data = try #require(next.floatChannelData)
        #expect(data[0][0] == 0.25)
        #expect(data[0][47] == 0.75)
        let following = try buffer { _, _ in -0.75 }
        splice.apply(to: following)
        #expect(try #require(following.floatChannelData)[0][0] == -0.75)
    }

    @Test func formatChangeDiscardsTheOldJoin() throws {
        var splice = AudioPacketSplice()
        splice.skip(try buffer(channels: 2) { _, _ in -1 })
        let next = try buffer(channels: 1) { _, _ in 0.5 }
        splice.apply(to: next)
        #expect(try #require(next.floatChannelData)[0][0] == 0.5)
        #expect(!splice.hasPendingJoin)
    }

    @Test func stallRecoveryDiscardsTheOldJoin() throws {
        let decoder = AudioDecoder()
        defer { decoder.shutdown() }
        let skipped = try buffer { _, _ in -0.5 }
        let next = try buffer { _, _ in 0.5 }
        decoder.inputFormat = skipped.format
        decoder.engine.attach(decoder.playerNode)
        decoder.engine.connect(decoder.playerNode, to: decoder.engine.mainMixerNode, format: skipped.format)
        try decoder.engine.enableManualRenderingMode(.offline, format: skipped.format, maximumFrameCount: 240)
        try decoder.engine.start()
        decoder.stateLock.withLock {
            decoder.packetSplice.skip(skipped)
            decoder.audioMeterLock.withLock { decoder.playoutStallPending = true }
            decoder.recoverIfPlayoutStalled()
            #expect(!decoder.packetSplice.hasPendingJoin)
            decoder.packetSplice.apply(to: next)
        }
        let data = try #require(next.floatChannelData)
        for channel in 0..<2 {
            for frame in 0..<240 { #expect(data[channel][frame] == 0.5) }
        }
    }

    @Test func shortPacketsStayWithinTheirBounds() throws {
        var splice = AudioPacketSplice()
        splice.skip(try buffer(frames: 2) { _, _ in -0.5 })
        let next = try buffer(frames: 2) { _, _ in 0.5 }
        splice.apply(to: next)
        let data = try #require(next.floatChannelData)
        #expect(data[0][0] == -0.5)
        #expect(data[0][1] == 0.5)
        #expect(next.frameLength == 2)
    }
}
