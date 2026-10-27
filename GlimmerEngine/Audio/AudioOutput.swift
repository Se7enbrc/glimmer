// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AVFAudio
import AudioToolbox

/// An adapter retains this storage until every unit using its callbacks has been disposed.
/// Callbacks execute entirely inside the engine with raw preallocated memory and atomics.
public final class AudioRenderStorage {
    let queue: UnsafeMutablePointer<AudioPCMQueue>
    private var mayRelease = true

    public init(channels: Int, capacity: Int = 48_000) {
        queue = .allocate(capacity: 1)
        queue.initialize(to: AudioPCMQueue(capacity: capacity, channels: channels))
    }

    #if os(macOS)
    package func resetProbe() { queue.pointee.outputProbe.reset() }
    #endif
    package func disable() { queue.pointee.enabled.store(false, ordering: .releasing) }

    public var renderCallback: AURenderCallbackStruct {
        AURenderCallbackStruct(inputProc: renderAudioPCM, inputProcRefCon: queue)
    }

    #if os(macOS)
    public var renderObserver: AURenderCallback { observeAudioOutput }
    #endif
    public var context: UnsafeMutableRawPointer { UnsafeMutableRawPointer(queue) }

    /// Invoke during adapter teardown, off the render thread. A failed disposal intentionally
    /// keeps raw storage alive because the system may still own a callback using it.
    public func dispose(using disposeUnits: () -> Bool) {
        queue.pointee.enabled.store(false, ordering: .releasing)
        let disposed = disposeUnits()
        mayRelease = mayRelease && disposed
    }

    deinit {
        guard mayRelease else { return }
        queue.deinitialize(count: 1)
        queue.deallocate()
    }
}

/// Graph, rate and health hooks run under the decoder's graph gate, never per packet or render pull.
/// Closures retain the adapter, which must stop and dispose its units before releasing storage.
public final class AudioOutput {
    public struct Failure: Error {
        public let status: OSStatus
        package var property: AudioUnitPropertyID = 0

        public init(status: OSStatus) { self.status = status }
        package init(status: OSStatus, property: AudioUnitPropertyID) {
            self.status = status
            self.property = property
        }
    }

    let storage: AudioRenderStorage
    let queue: UnsafeMutablePointer<AudioPCMQueue>
    let sampleRate: Double
    let channels: UInt32
    let latencyMs: Double
    let spatial: Bool
    private let startOutput: () -> OSStatus
    private let running: () -> Bool
    private let rate: (Float) -> OSStatus
    let lastRenderError: () -> OSStatus
    #if os(macOS)
    var outputSilence = AudioOutputSilence()
    #endif

    public init(storage: AudioRenderStorage, sampleRate: Double, channels: UInt32, latencyMs: Double,
                spatial: Bool = false, start: @escaping () -> OSStatus, isRunning: @escaping () -> Bool,
                setRate: @escaping (Float) -> OSStatus, lastRenderError: @escaping () -> OSStatus) {
        self.storage = storage
        self.queue = storage.queue
        self.sampleRate = sampleRate
        self.channels = channels
        self.latencyMs = latencyMs
        self.spatial = spatial
        self.startOutput = start
        self.running = isRunning
        self.rate = setRate
        self.lastRenderError = lastRenderError
    }

    func start() -> OSStatus { startOutput() }
    var isRunning: Bool { running() }
    func setRate(_ value: Float) -> OSStatus { rate(value) }
}
