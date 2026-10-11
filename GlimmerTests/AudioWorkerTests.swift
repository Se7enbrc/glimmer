// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AVFoundation
import Foundation
import Testing
import os
@testable import Glimmer

struct AudioWorkerTests {
    @Test func queuePreservesOrderAndDropsNewestAtCapacity() async {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let values = OSAllocatedUnfairLock(initialState: [UInt8]())
        let worker = AudioPacketWorker(capacity: 2, configureThread: {}, consume: { packet, _ in
            if packet == [1] { entered.signal(); release.wait() }
            values.withLock { $0.append(contentsOf: packet) }
            finished.signal()
        })
        worker.start()
        defer { worker.stop() }
        #expect(worker.enqueue([1], count: 1, arrival: DispatchTime.now().uptimeNanoseconds))
        #expect(await entered.waitAsync(for: .seconds(2)) == .success)
        #expect(worker.enqueue([2], count: 1, arrival: DispatchTime.now().uptimeNanoseconds))
        #expect(worker.enqueue([3], count: 1, arrival: DispatchTime.now().uptimeNanoseconds))
        #expect(!worker.enqueue([4], count: 1, arrival: DispatchTime.now().uptimeNanoseconds))
        release.signal()
        for _ in 0..<3 { #expect(await finished.waitAsync(for: .seconds(2)) == .success) }
        #expect(values.withLock { $0 } == [1, 2, 3])
    }

    @Test func stopJoinsInFlightDecodeAndRestartDiscardsOldPackets() async {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0)
        let stopRequested = DispatchSemaphore(value: 0)
        let next = DispatchSemaphore(value: 0)
        let values = OSAllocatedUnfairLock(initialState: [UInt8]())
        let worker = AudioPacketWorker(configureThread: {}, consume: { packet, _ in
            if packet == [1] { entered.signal(); release.wait() }
            values.withLock { $0.append(contentsOf: packet) }
            if packet == [3] { next.signal() }
        })
        worker.stop()
        worker.start()
        #expect(!worker.enqueue([1], count: -1, arrival: 0))
        #expect(!worker.enqueue([1], count: 2, arrival: 0))
        #expect(worker.enqueue([1], count: 1, arrival: DispatchTime.now().uptimeNanoseconds))
        #expect(await entered.waitAsync(for: .seconds(2)) == .success)
        #expect(worker.enqueue([2], count: 1, arrival: DispatchTime.now().uptimeNanoseconds))
        DispatchQueue.global().async {
            worker.stop(onStopping: { stopRequested.signal() })
            stopped.signal()
        }
        #expect(await stopRequested.waitAsync(for: .seconds(2)) == .success)
        #expect(await stopped.waitAsync(for: .milliseconds(50)) == .timedOut)
        release.signal()
        #expect(await stopped.waitAsync(for: .seconds(2)) == .success)
        #expect(!worker.enqueue([9], count: 1, arrival: DispatchTime.now().uptimeNanoseconds))
        worker.start()
        worker.start()
        defer { worker.stop() }
        #expect(worker.enqueue([3], count: 1, arrival: DispatchTime.now().uptimeNanoseconds))
        #expect(await next.waitAsync(for: .seconds(2)) == .success)
        #expect(values.withLock { $0 } == [1, 3])
    }

    @Test func cancellationDoesNotWaitForAnInFlightCallback() async {
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let worker = AudioPacketWorker(configureThread: {}, consume: { _, _ in
            entered.signal()
            release.wait()
        })
        worker.start()
        #expect(worker.enqueue([1], count: 1, arrival: DispatchTime.now().uptimeNanoseconds))
        #expect(await entered.waitAsync(for: .seconds(2)) == .success)
        worker.requestStop()
        #expect(!worker.enqueue([2], count: 1, arrival: DispatchTime.now().uptimeNanoseconds))
        release.signal()
        worker.stop()
    }

    @Test func graphChangeReleasesDecodeLockAndAdmissionRecovers() async {
        let decoder = AudioDecoder()
        defer { decoder.shutdown() }
        decoder.beginGraphChange()
        let returned = DispatchSemaphore(value: 0)
        DispatchQueue.global(qos: .userInteractive).async {
            let acquired = decoder.stateLock.try()
            #expect(acquired)
            if acquired { decoder.stateLock.unlock() }
            decoder.decodeAndPlayPLC()
            returned.signal()
        }
        #expect(await returned.waitAsync(for: .seconds(2)) == .success)
        #expect(decoder.graphChanging)
        decoder.endGraphChange()
        #expect(!decoder.graphChanging)
        decoder.beginGraphChange()
        decoder.endGraphChange()
        #expect(!decoder.graphChanging)
    }

    @Test func pcmPoolCannotRecycleAnOutstandingBuffer() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let pool = AudioPCMBufferPool(format: format, frames: 240, count: 2)
        let first = try #require(pool.acquire())
        let second = try #require(pool.acquire())
        #expect(first.buffer !== second.buffer)
        #expect(pool.acquire() == nil)
        pool.release(first.index)
        let recycled = try #require(pool.acquire())
        #expect(recycled.buffer === first.buffer)
        pool.release(recycled.index)
        pool.release(second.index)
    }

    @Test func telemetryWindowsResetButHistogramsAndUnderrunsAccumulate() {
        let telemetry = AudioPipelineTelemetry()
        telemetry.receiveGap.observe(5)
        telemetry.receiveGap.observe(20)
        telemetry.decodeSchedule.observe(0.5)
        telemetry.stateLockWait.observe(0.1)
        telemetry.noteRender(cushionMs: 12, underrun: false)
        telemetry.noteRender(cushionMs: 0, underrun: true)
        telemetry.noteNearMiss()
        let first = telemetry.takeSnapshot()
        #expect(first.receiveGap.observationCount == 2)
        #expect(first.receiveGap.sumMs == 25)
        let fiveMs = first.receiveGap.boundsMs.firstIndex(of: 5)
        #expect(fiveMs.map { first.receiveGap.buckets[$0] } == 1)
        #expect(first.window.minimumRenderCushionMs == 0)
        #expect(first.window.renderUnderruns == 1)
        #expect(first.window.nearMisses == 1)
        let next = telemetry.takeSnapshot()
        #expect(next.window.minimumRenderCushionMs == nil)
        #expect(next.window.nearMisses == 0)
        #expect(next.window.renderUnderruns == 1)
        #expect(next.receiveGap.observationCount == 2)
        telemetry.reset()
        #expect(telemetry.takeSnapshot().receiveGap.observationCount == 0)
    }

    @Test func renderClockDetectsStarvationWithoutAnyCompletionCallbacks() {
        var clock = AudioRenderTimeline()
        clock.renderQuantum = 240
        clock.scheduled(frames: 1_440, at: nil)
        #expect(clock.observe(sample: 0, rate: 48_000) == nil)
        #expect(clock.observe(sample: 240, rate: 48_000)?.cushionMs == 25)
        #expect(clock.observe(sample: 1_440, rate: 48_000)?.underrun == false)
        #expect(clock.observe(sample: 1_920, rate: 48_000)?.underrun == true)
        #expect(clock.observe(sample: 2_160, rate: 48_000)?.underrun == false)
        clock.scheduled(frames: 480, at: 2_160)
        #expect(clock.observe(sample: 2_400, rate: 48_000)?.underrun == false)
        #expect(clock.observe(sample: 3_120, rate: 48_000)?.underrun == true)
        clock = AudioRenderTimeline()
        #expect(clock.observe(sample: 4_000, rate: 48_000) == nil)
    }

    @Test func bothExportersCarryAudioPipelineMeasurements() {
        let telemetry = AudioPipelineTelemetry()
        telemetry.receiveGap.observe(5)
        telemetry.noteRender(cushionMs: 3, underrun: true)
        telemetry.noteNearMiss()
        let snapshot = telemetry.takeSnapshot()
        var json = TelemetryRenderer.NDJSONBuilder()
        TelemetryRenderer.ndjsonAudioPipeline(&json, snapshot)
        #expect(json.line().contains("\"audio_render_underrun_total\":1"))
        #expect(json.line().contains("\"audio_near_misses_window\":1"))
        #expect(json.line().contains("\"audio_receive_gap_buckets\":"))
        var prom = TelemetryRenderer.PromBuilder(session: "test", host: "pc")
        TelemetryRenderer.promAudioPipeline(&prom, snapshot)
        #expect(prom.out.contains("glimmer_audio_receive_gap_ms_bucket"))
        #expect(prom.out.contains("glimmer_audio_render_cushion_min_ms"))
    }

    @Test func oldCompletionCannotAdvanceAReconnectedMeter() {
        let decoder = AudioDecoder()
        decoder.meterGeneration = 2
        decoder.framesScheduled = 480
        decoder.meterCompleteOnePlayout(frames: 240, generation: 1)
        #expect(decoder.framesPlayed == 0)
        decoder.meterCompleteOnePlayout(frames: 240, generation: 2)
        #expect(decoder.framesPlayed == 240)
        decoder.shutdown()
    }

    @Test func realPlayerRenderClockContinuesAfterScheduledAudioRunsOut() throws {
        let engine = AVAudioEngine()
        let player = AVAudioPlayerNode()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        try engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 240)
        let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 1_440))
        input.frameLength = 1_440
        if let channels = input.floatChannelData {
            for channel in 0..<2 { channels[channel].update(repeating: 0, count: 1_440) }
        }
        let output = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 240))
        player.scheduleBuffer(input)
        try engine.start()
        player.play()
        defer { player.stop(); engine.stop() }
        var timeline = AudioRenderTimeline()
        timeline.renderQuantum = 240
        timeline.scheduled(frames: 1_440, at: nil)
        var underruns = 0
        for quantum in 0..<20 {
            #expect(try engine.renderOffline(240, to: output) == .success)
            let render = try #require(player.lastRenderTime)
            let time = try #require(player.playerTime(forNodeTime: render))
            let observation = timeline.observe(sample: time.sampleTime, rate: time.sampleRate)
            if observation?.underrun == true { underruns += 1 }
            if quantum < 6 { #expect(underruns == 0) }
        }
        #expect(underruns == 1)
    }
}
