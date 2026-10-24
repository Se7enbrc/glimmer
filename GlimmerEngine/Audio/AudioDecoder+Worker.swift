// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AVFoundation
import Foundation

extension AudioDecoder {
    /// Lifecycle callers serialize here, then close decode admission before touching the graph.
    /// The decode lock is released during HAL graph work; incoming packets never wait on it.
    func beginGraphChange() {
        graphChangeLock.lock()
        stateLock.lock()
        graphChanging = true
        stateLock.unlock()
    }

    func endGraphChange() {
        stateLock.lock()
        graphChanging = false
        stateLock.unlock()
        graphChangeLock.unlock()
    }

    func preparePCMStorage(format: AVAudioFormat) {
        decodeScratch = [Float](repeating: 0, count: samplesPerFrame * channelCount)
        let capacity = max(128, Int(format.sampleRate * 0.4) / samplesPerFrame + 2)
        pcmPool = AudioPCMBufferPool(format: format, frames: AVAudioFrameCount(samplesPerFrame), count: capacity)
        silencePool = makeSilencePool(format: format)
    }

    func makeSilencePool(format: AVAudioFormat) -> AudioPCMBufferPool {
        AudioPCMBufferPool(format: format, frames: AVAudioFrameCount(format.sampleRate * 0.3), count: 4)
    }

    func resetPacketSplice() {
        packetSplice = AudioPacketSplice()
        if let held = spliceLease { held.pool.release(held.index) }
        spliceLease = nil
    }

    func makeLinkResolveSource() -> DispatchSourceUserDataAdd {
        let source = DispatchSource.makeUserDataAddSource(queue: routeListenerQueue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.graphChangeLock.lock()
            defer { self.graphChangeLock.unlock() }
            guard !self.isShutdown else { return }
            self.resolveCushionLink()
        }
        source.activate()
        return source
    }

    func makeMaintenanceSource() -> DispatchSourceUserDataAdd {
        let source = DispatchSource.makeUserDataAddSource(queue: routeListenerQueue)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.beginGraphChange()
            defer { self.endGraphChange() }
            guard !self.isShutdown else { return }
            self.recoverIfPlayoutStalled()
            _ = self.ensureEngineAtPrimeEdge(now: DispatchTime.now().uptimeNanoseconds)
        }
        source.activate()
        return source
    }

    func installRenderMonitor() {
        renderMonitor?.cancel()
        renderProgress = AudioRenderProgress()
        let timer = DispatchSource.makeTimerSource(queue: routeListenerQueue)
        timer.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            guard let self, self.stateLock.try() else { return }
            defer { self.stateLock.unlock() }
            guard !self.graphChanging, !self.isShutdown else { return }
            #if os(macOS) || GLIMMER_DIAGNOSTICS
            self.halOutput?.observeOutputSilence()
            #endif
            let frames = self.observeRenderClock()
            if self.renderProgress.needsRunningCheck(frames: frames) { self.refreshOutputRunningState() }
            if !self.engineRunning { self.maintenanceSource.add(data: 1) }
        }
        renderMonitor = timer
        timer.activate()
    }

    @discardableResult
    func observeRenderClock(telemetry: AudioPipelineInstrumentation? = .shared,
                            counters: TelemetryCounters = .shared) -> Int64? {
        guard let output = halOutput else { return nil }
        let queue = output.queue
        guard let observation = queue.pointee.observation() else { return nil }
        let consumed = observation.frames
        let silent = observation.silence
        let underruns = observation.underruns
        let frames = consumed &- observedRingFrames
        #if os(macOS) || GLIMMER_DIAGNOSTICS
        if frames > 0 { telemetry?.renderedFrames.wrappingAdd(frames, ordering: .relaxed) }
        #endif
        let silenceFrames = silent &- observedRingSilence
        let edges = underruns &- observedRingUnderruns
        observedRingFrames = consumed
        observedRingSilence = silent
        observedRingUnderruns = underruns
        audioMeterLock.withLock { pendingSilenceFrames -= min(pendingSilenceFrames, silenceFrames) }
        let minimum = queue.pointee.minimumFill.exchange(Int.max, ordering: .relaxed)
        if frames > 0 || edges > 0 || minimum != Int.max {
            meterCompleteOnePlayout(frames: frames, confirmedUnderrun: edges > 0,
                                    minimumFillFrames: minimum == Int.max ? nil : minimum, counters: counters)
        }
        #if os(macOS) || GLIMMER_DIAGNOSTICS
        if minimum != Int.max {
            let fill = Double(minimum) / meterSampleRate * 1000
            telemetry?.noteRender(cushionMs: fill, underrun: false)
        }
        #endif
        #if os(macOS) || GLIMMER_DIAGNOSTICS
        for _ in 0..<edges { telemetry?.noteRender(cushionMs: 0, underrun: true) }
        #endif
        if deviceRecoveryStarted != 0, frames > 0 {
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds &- deviceRecoveryStarted) / 1_000_000
            deviceRecoveryStarted = 0
            #if os(macOS) || GLIMMER_DIAGNOSTICS
            telemetry?.noteOutput(latencyMs: output.latencyMs, recoveryMs: elapsed)
            #endif
            AudioDiagnostics.notice("audio device recovery: \(elapsed)ms to rendered PCM", "Stream.Audio")
        }
        return Int64(consumed)
    }

    func enqueuePCM(_ buffer: AVAudioPCMBuffer, isSilence: Bool, completion: @Sendable () -> Void) {
        defer { completion() }
        guard let output = halOutput, let channels = buffer.floatChannelData else {
            audioMeterLock.withLock {
                framesScheduled -= UInt64(buffer.frameLength)
                if isSilence { pendingSilenceFrames -= min(pendingSilenceFrames, UInt64(buffer.frameLength)) }
            }
            return
        }
        if !output.queue.pointee.write(channels, frames: Int(buffer.frameLength), isSilence: isSilence) {
            audioMeterLock.withLock {
                framesScheduled -= UInt64(buffer.frameLength)
                if isSilence { pendingSilenceFrames -= min(pendingSilenceFrames, UInt64(buffer.frameLength)) }
            }
            TelemetryCounters.shared.audioOverrunTotal.increment()
        }
    }
}

/// The worker releases slots after copying PCM into the ring; the lock guards only the free list.
final class AudioPCMBufferPool: @unchecked Sendable {
    struct Lease {
        let pool: AudioPCMBufferPool
        let index: Int
        var buffer: AVAudioPCMBuffer { pool.buffers[index] }
        var completion: @Sendable () -> Void { pool.completions[index] }
    }
    private let lock = NSLock()
    private let buffers: [AVAudioPCMBuffer]
    private var available: [Int]
    // Created before publication; the worker only reads these closures.
    private var completions: [@Sendable () -> Void] = []

    init(format: AVAudioFormat, frames: AVAudioFrameCount, count: Int,
         completed: @escaping @Sendable (UInt64) -> Void = { _ in }) {
        buffers = (0..<count).compactMap { _ in AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames) }
        available = Array(buffers.indices)
        available.reserveCapacity(count)
        completions = buffers.indices.map { index in
            { [weak self] in
                guard let self else { return }
                let frames = UInt64(self.buffers[index].frameLength)
                self.release(index)
                completed(frames)
            }
        }
    }

    func acquire() -> Lease? {
        lock.withLock {
            guard let index = available.popLast() else { return nil }
            return Lease(pool: self, index: index)
        }
    }

    func release(_ index: Int) {
        lock.withLock { available.append(index) }
    }
}

// Render progress proves HAL is running; query the device only when that evidence stops.
struct AudioRenderProgress {
    init() {}

    private var lastFrames: Int64?

    mutating func needsRunningCheck(frames: Int64?) -> Bool {
        defer { lastFrames = frames }
        guard let frames, let lastFrames else { return true }
        return frames <= lastFrames
    }
}
