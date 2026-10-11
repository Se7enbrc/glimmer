// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AVFoundation
import Foundation

extension AudioDecoder {
    /// Lifecycle callers serialize here, then close decode admission before touching the graph.
    /// The decode lock is released during HAL and AVAudioEngine work; incoming packets never wait on it.
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
        let generation = audioMeterLock.withLock { meterGeneration }
        let capacity = max(128, Int(format.sampleRate * 0.4) / samplesPerFrame + 2)
        pcmPool = AudioPCMBufferPool(format: format, frames: AVAudioFrameCount(samplesPerFrame), count: capacity,
                                     completed: { [weak self] frames in
            self?.meterCompleteOnePlayout(frames: frames, generation: generation)
        })
        silencePool = makeSilencePool(format: format)
    }

    func makeSilencePool(format: AVAudioFormat) -> AudioPCMBufferPool {
        let generation = audioMeterLock.withLock { meterGeneration }
        return AudioPCMBufferPool(format: format, frames: AVAudioFrameCount(format.sampleRate * 0.3), count: 4,
                                  completed: { [weak self] frames in
            self?.meterCompleteOnePlayout(frames: frames, isSilence: true, generation: generation)
        })
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
            if !self.engine.isRunning {
                _ = self.ensureEngineAtPrimeEdge(now: DispatchTime.now().uptimeNanoseconds)
            }
        }
        source.activate()
        return source
    }

    func installRenderMonitor() {
        renderMonitor?.cancel()
        let timer = DispatchSource.makeTimerSource(queue: routeListenerQueue)
        timer.schedule(deadline: .now() + .milliseconds(10), repeating: .milliseconds(10))
        timer.setEventHandler { [weak self] in
            guard let self, self.stateLock.try() else { return }
            defer { self.stateLock.unlock() }
            guard !self.graphChanging, !self.isShutdown else { return }
            _ = self.observeRenderClock()
        }
        renderMonitor = timer
        timer.activate()
    }

    func observeRenderClock() -> Int64? {
        guard playerNode.isPlaying, let render = playerNode.lastRenderTime,
              let time = playerNode.playerTime(forNodeTime: render), time.isSampleTimeValid else { return nil }
        if let observation = renderTimeline.observe(sample: time.sampleTime, rate: time.sampleRate) {
            AudioPipelineTelemetry.shared.noteRender(cushionMs: observation.cushionMs, underrun: observation.underrun)
        }
        return time.sampleTime
    }
}

/// Slots are leased until dataConsumed returns ownership; the lock guards only the free list.
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
    // Created before publication; the worker and AV callbacks only read these closures.
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

// Formatting and preferences can block; their work never belongs to the packet or render threads.
enum AudioDiagnostics {
    static let queue = DispatchQueue(label: "io.ugfugl.Glimmer.audio.diagnostics", qos: .utility)

    static func notice(_ message: @autoclosure @escaping @Sendable () -> DiagMessage, _ category: String) {
        queue.async { Diag.notice(message(), category) }
    }

    static func warn(_ message: @autoclosure @escaping @Sendable () -> DiagMessage, _ category: String) {
        queue.async { Diag.warn(message(), category) }
    }

    static func error(_ message: @autoclosure @escaping @Sendable () -> DiagMessage, _ category: String) {
        queue.async { Diag.error(message(), category) }
    }

    static func info(_ message: @autoclosure @escaping @Sendable () -> DiagMessage, _ category: String) {
        queue.async { Diag.info(message(), category) }
    }
}
