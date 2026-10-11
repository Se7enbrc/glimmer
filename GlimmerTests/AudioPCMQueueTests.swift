// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AVFAudio
import AudioToolbox
import Foundation
import Testing
@testable import Glimmer

struct AudioPCMQueueTests {
    private func buffer(frames: Int, channels: Int = 2) throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000,
                                               channels: UInt32(channels)))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: UInt32(frames)))
        buffer.frameLength = UInt32(frames)
        return buffer
    }

    @Test func wrapOverrunAndPartialUnderrunPreserveOrder() throws {
        let graph = AudioHALOutput(channels: 2, capacity: 8)
        let input = try buffer(frames: 6)
        let source = try #require(input.floatChannelData)
        for channel in 0..<2 {
            for frame in 0..<6 { source[channel][frame] = Float(frame + channel * 10) }
        }
        let queue = graph.queue
        #expect(Bool(queue.pointee.write(source, frames: 6, isSilence: false)))
        #expect(Bool(!queue.pointee.write(source, frames: 6, isSilence: false)))
        let output = try buffer(frames: 8)
        queue.pointee.enabled.store(true, ordering: .releasing)
        #expect(Bool(queue.pointee.render(frames: 4, buffers: output.mutableAudioBufferList) == noErr))
        #expect(Bool(queue.pointee.write(source, frames: 6, isSilence: true)))
        #expect(Bool(queue.pointee.render(frames: 8, buffers: output.mutableAudioBufferList) == noErr))
        let samples = try #require(output.floatChannelData)
        #expect(Array(UnsafeBufferPointer(start: samples[0], count: 8)) == [4, 5, 0, 1, 2, 3, 4, 5])
        #expect(Array(UnsafeBufferPointer(start: samples[1], count: 8)) == [14, 15, 10, 11, 12, 13, 14, 15])
        #expect(queue.pointee.silenceConsumed.load(ordering: .acquiring) == 6)
        // Exact exhaustion is not an underrun until a later callback requests missing samples.
        #expect(queue.pointee.underruns.load(ordering: .acquiring) == 0)
        #expect(Bool(queue.pointee.write(source, frames: 2, isSilence: false)))
        #expect(Bool(queue.pointee.render(frames: 8, buffers: output.mutableAudioBufferList) == noErr))
        #expect(Array(UnsafeBufferPointer(start: samples[0], count: 8)) == [0, 1, 0, 0, 0, 0, 0, 0])
        #expect(queue.pointee.underruns.load(ordering: .acquiring) == 1)
        #expect(Bool(queue.pointee.render(frames: 8, buffers: output.mutableAudioBufferList) == noErr))
        #expect(queue.pointee.underruns.load(ordering: .acquiring) == 1)
    }

    @Test func oversizedRenderRequestCannotOverflowByteCount() throws {
        let graph = AudioHALOutput(channels: 2)
        let output = try buffer(frames: 1)
        #expect(Bool(graph.queue.pointee.render(frames: Int.max,
            buffers: output.mutableAudioBufferList) == kAudio_ParamError))
        #expect(graph.queue.pointee.consumed.load(ordering: .acquiring) == 0)
    }

    @Test func prerollAndMuteDoNotInventUnderruns() throws {
        let graph = AudioHALOutput(channels: 2, capacity: 8)
        let input = try buffer(frames: 4)
        let source = try #require(input.floatChannelData)
        for channel in 0..<2 { source[channel].update(repeating: 1, count: 4) }
        #expect(Bool(graph.queue.pointee.write(source, frames: 4, isSilence: false)))
        let output = try buffer(frames: 4)
        #expect(Bool(graph.queue.pointee.render(frames: 4, buffers: output.mutableAudioBufferList) == noErr))
        #expect(graph.queue.pointee.consumed.load(ordering: .acquiring) == 0)
        #expect(graph.queue.pointee.underruns.load(ordering: .acquiring) == 0)
        graph.queue.pointee.enabled.store(true, ordering: .releasing)
        graph.queue.pointee.muted.store(true, ordering: .relaxed)
        #expect(Bool(graph.queue.pointee.render(frames: 4, buffers: output.mutableAudioBufferList) == noErr))
        let samples = try #require(output.floatChannelData)
        #expect(Array(UnsafeBufferPointer(start: samples[0], count: 4)) == [0, 0, 0, 0])
        #expect(graph.queue.pointee.consumed.load(ordering: .acquiring) == 4)
    }

    // The producer and consumer access disjoint PCM buffers; the shared queue publishes only through atomics.
    private final class ConcurrentRing: @unchecked Sendable {
        let graph = AudioHALOutput(channels: 2, capacity: 64)
        let input: AVAudioPCMBuffer
        let output: AVAudioPCMBuffer
        init(input: AVAudioPCMBuffer, output: AVAudioPCMBuffer) {
            self.input = input
            self.output = output
        }
    }

    @Test func concurrentProducerConsumerPreserveSPSCOrdering() async throws {
        let ring = ConcurrentRing(input: try buffer(frames: 1), output: try buffer(frames: 1))
        ring.graph.queue.pointee.enabled.store(true, ordering: .releasing)
        async let producer: Void = Task.detached {
            guard let samples = ring.input.floatChannelData else { Issue.record("Missing PCM"); return }
            for sequence in 1...20_000 {
                samples[0][0] = Float(sequence)
                samples[1][0] = -Float(sequence)
                while !ring.graph.queue.pointee.write(samples, frames: 1, isSilence: false) { await Task.yield() }
            }
        }.value
        async let consumer: Void = Task.detached {
            guard let samples = ring.output.floatChannelData else { Issue.record("Missing PCM"); return }
            for sequence in 1...20_000 {
                let before = ring.graph.queue.pointee.consumed.load(ordering: .acquiring)
                repeat {
                    #expect(Bool(ring.graph.queue.pointee.render(frames: 1,
                        buffers: ring.output.mutableAudioBufferList) == noErr))
                } while ring.graph.queue.pointee.consumed.load(ordering: .acquiring) == before
                #expect(samples[0][0] == Float(sequence))
                #expect(samples[1][0] == -Float(sequence))
            }
        }.value
        _ = await (producer, consumer)
    }

    @Test func ringConsumptionFeedsMeterWithoutCountingExactEmptyAsStarvation() throws {
        let decoder = AudioDecoder()
        defer { decoder.shutdown() }
        let input = try buffer(frames: 240)
        let data = try #require(input.floatChannelData)
        for channel in 0..<2 { data[channel].update(repeating: 0.5, count: 240) }
        decoder.halOutput = AudioHALOutput(channels: 2)
        let graph = try #require(decoder.halOutput)
        #expect(!decoder.meterRegisterScheduleOrOverrun(frames: 240))
        decoder.enqueuePCM(input, isSilence: false, completion: {})
        graph.queue.pointee.enabled.store(true, ordering: .releasing)
        let output = try buffer(frames: 240)
        #expect(Bool(graph.queue.pointee.render(frames: 240, buffers: output.mutableAudioBufferList) == noErr))
        decoder.observeRenderClock()
        #expect(decoder.framesPlayed == 240)
        #expect(!decoder.playoutDrained)
        #expect(Bool(graph.queue.pointee.render(frames: 240, buffers: output.mutableAudioBufferList) == noErr))
        decoder.observeRenderClock()
        #expect(decoder.playoutDrained)
        #expect(decoder.pendingUnderrunTargetMs == decoder.playoutTargetMs)
    }
    @Test func underrunPublicationSurvivesAnAlreadyReadMinimumWindow() {
        let decoder = AudioDecoder()
        defer { decoder.shutdown() }
        decoder.halOutput = AudioHALOutput(channels: 2)
        let telemetry = AudioPipelineTelemetry()
        decoder.halOutput?.queue.pointee.underruns.store(1, ordering: .releasing)
        decoder.observeRenderClock(telemetry: telemetry)
        #expect(telemetry.takeSnapshot().window.renderUnderruns == 1)
    }

    @Test(arguments: [false, true])
    func renderTroughSurvivesWritesBeforeObservation(windowExpired: Bool) throws {
        let decoder = AudioDecoder()
        defer { decoder.shutdown() }
        decoder.halOutput = AudioHALOutput(channels: 2)
        let graph = try #require(decoder.halOutput)
        let input = try buffer(frames: 2_400)
        let data = try #require(input.floatChannelData)
        decoder.meterSampleRate = 48_000
        decoder.playoutStarted = true
        decoder.playoutTargetMs = 60
        decoder.framesScheduled = 2_400
        #expect(Bool(graph.queue.pointee.write(data, frames: 2_400, isSilence: false)))
        graph.queue.pointee.enabled.store(true, ordering: .releasing)
        let output = try buffer(frames: 2_160)
        #expect(Bool(graph.queue.pointee.render(frames: 2_160, buffers: output.mutableAudioBufferList) == noErr))
        decoder.framesScheduled += 2_400
        #expect(Bool(graph.queue.pointee.write(data, frames: 2_400, isSilence: false)))
        let now = DispatchTime.now().uptimeNanoseconds
        decoder.quietSinceNanos = windowExpired ? now &- AudioDecoder.playoutDecayQuietNanos : now
        decoder.floorQuietSinceNanos = now
        let counters = TelemetryCounters()
        decoder.observeRenderClock(telemetry: AudioPipelineTelemetry(), counters: counters)
        #expect(counters.takeAudioBufferFillMinMs() == 5)
        #expect(decoder.quietWindowMinFillMs == (windowExpired ? .infinity : 5))
        #expect(decoder.playoutTargetMs == 60)
    }

    @Test func observationNeverCombinesDifferentRenderPulls() {
        let graph = AudioHALOutput(channels: 2)
        graph.queue.pointee.observationVersion.store(1, ordering: .releasing)
        graph.queue.pointee.silenceConsumed.store(12, ordering: .relaxed)
        #expect(graph.queue.pointee.observation() == nil)
        graph.queue.pointee.consumed.store(24, ordering: .relaxed)
        graph.queue.pointee.observationVersion.store(2, ordering: .releasing)
        let observation = graph.queue.pointee.observation()
        #expect(observation?.frames == 24)
        #expect(observation?.silence == 12)
    }
}
