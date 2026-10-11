// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AVFoundation
import Foundation
import Testing
import os
@testable import Glimmer

struct AudioWorkerTests {
    @Test func progressingAudioSkipsHALQueriesButStallsAndResetsStillCheck() {
        var progress = AudioRenderProgress()
        let samples: [(Int64?, Bool)] = [(nil, true), (0, true), (240, false), (480, false),
                                          (480, true), (720, false), (0, true), (nil, true)]
        for (frames, expected) in samples {
            let check = progress.needsRunningCheck(frames: frames)
            #expect(check == expected)
        }
    }

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

    @Test func bothExportersCarryAudioPipelineMeasurements() {
        let telemetry = AudioPipelineTelemetry()
        telemetry.receiveGap.observe(5)
        telemetry.noteRender(cushionMs: 3, underrun: true)
        telemetry.noteNearMiss()
        telemetry.noteOutput(latencyMs: 12, recoveryMs: 90)
        let snapshot = telemetry.takeSnapshot()
        var json = TelemetryRenderer.NDJSONBuilder()
        TelemetryRenderer.ndjsonAudioPipeline(&json, snapshot)
        #expect(json.line().contains("\"audio_render_underrun_total\":1"))
        #expect(json.line().contains("\"audio_near_misses_window\":1"))
        #expect(json.line().contains("\"audio_receive_gap_buckets\":"))
        #expect(json.line().contains("\"audio_device_recovery_ms\":90"))
        #expect(json.line().contains("\"audio_output_latency_ms\":12"))
        var prom = TelemetryRenderer.PromBuilder(session: "test", host: "pc")
        TelemetryRenderer.promAudioPipeline(&prom, snapshot)
        #expect(prom.out.contains("glimmer_audio_receive_gap_ms_bucket"))
        #expect(prom.out.contains("glimmer_audio_render_cushion_min_ms"))
    }
}
