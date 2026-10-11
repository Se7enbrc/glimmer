// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AudioToolbox
import Synchronization

// The worker alone publishes samples; one render thread consumes them. Storage outlives the stopped units.
// The callback touches only raw preallocated memory and lock-free atomics: no ARC, locks or logging.
struct AudioPCMQueue: ~Copyable {
    let capacity: Int
    let channels: Int
    let samples: UnsafeMutablePointer<Float>
    let silence: UnsafeMutablePointer<UInt8>
    let written = Atomic<UInt64>(0)
    let consumed = Atomic<UInt64>(0)
    let silenceConsumed = Atomic<UInt64>(0)
    let underruns = Atomic<UInt64>(0)
    let observationVersion = Atomic<UInt64>(0)
    let minimumFill = Atomic<Int>(Int.max)
    let enabled = Atomic<Bool>(false)
    let muted = Atomic<Bool>(false)
    // Only the render callback touches this latch, and only after initialization.
    let drained = Atomic<Bool>(false)

    init(capacity: Int, channels: Int) {
        precondition(capacity > 0 && channels > 0)
        self.capacity = capacity
        self.channels = channels
        samples = .allocate(capacity: capacity * channels)
        samples.initialize(repeating: 0, count: capacity * channels)
        silence = .allocate(capacity: capacity)
        silence.initialize(repeating: 0, count: capacity)
    }

    deinit {
        samples.deallocate()
        silence.deallocate()
    }

    func write(_ source: UnsafePointer<UnsafeMutablePointer<Float>>, frames: Int, isSilence: Bool) -> Bool {
        let end = written.load(ordering: .relaxed)
        let start = consumed.load(ordering: .acquiring)
        guard frames >= 0, frames <= capacity - Int(end &- start) else { return false }
        for frame in 0..<frames {
            let slot = Int((end &+ UInt64(frame)) % UInt64(capacity))
            for channel in 0..<channels { samples[channel * capacity + slot] = source[channel][frame] }
            silence[slot] = isSilence ? 1 : 0
        }
        written.store(end &+ UInt64(frames), ordering: .releasing)
        return true
    }

    func render(frames: Int, buffers: UnsafeMutablePointer<AudioBufferList>) -> OSStatus {
        guard frames >= 0 else { return kAudio_ParamError }
        guard Int(buffers.pointee.mNumberBuffers) == channels else { return kAudioUnitErr_FormatNotSupported }
        let offset = MemoryLayout<AudioBufferList>.size - MemoryLayout<AudioBuffer>.size
        let output = UnsafeMutableRawPointer(buffers).advanced(by: offset).assumingMemoryBound(to: AudioBuffer.self)
        for channel in 0..<channels {
            guard output[channel].mData != nil,
                  output[channel].mDataByteSize >= frames * MemoryLayout<Float>.size else {
                return kAudioUnitErr_TooManyFramesToProcess
            }
        }
        let start = consumed.load(ordering: .relaxed)
        let end = written.load(ordering: .acquiring)
        let active = enabled.load(ordering: .acquiring)
        let count = active ? min(frames, Int(end &- start)) : 0
        let gain: Float = muted.load(ordering: .relaxed) ? 0 : 1
        for channel in 0..<channels {
            guard let data = output[channel].mData?.assumingMemoryBound(to: Float.self) else { continue }
            for frame in 0..<count {
                let slot = Int((start &+ UInt64(frame)) % UInt64(capacity))
                data[frame] = samples[channel * capacity + slot] * gain
            }
            if frames > count { data.advanced(by: count).update(repeating: 0, count: frames - count) }
        }
        guard active else { return noErr }
        var silent: UInt64 = 0
        for frame in 0..<count { silent += UInt64(silence[Int((start &+ UInt64(frame)) % UInt64(capacity))]) }
        observationVersion.wrappingAdd(1, ordering: .acquiringAndReleasing)
        silenceConsumed.wrappingAdd(silent, ordering: .relaxed)
        consumed.store(start &+ UInt64(count), ordering: .releasing)
        minimumFill.min(Int(end &- start) - count, ordering: .relaxed)
        if count < frames {
            if !drained.exchange(true, ordering: .relaxed) { underruns.wrappingAdd(1, ordering: .releasing) }
        } else {
            drained.store(false, ordering: .relaxed)
        }
        observationVersion.wrappingAdd(1, ordering: .releasing)
        return noErr
    }

    // The observer may skip an in-flight update; silence and consumption must describe the same pull.
    func observation() -> (frames: UInt64, silence: UInt64, underruns: UInt64)? {
        let version = observationVersion.load(ordering: .acquiring)
        guard version.isMultiple(of: 2) else { return nil }
        let result = (consumed.load(ordering: .acquiring), silenceConsumed.load(ordering: .acquiring),
                      underruns.load(ordering: .acquiring))
        guard observationVersion.load(ordering: .acquiring) == version else { return nil }
        return result
    }
}

func renderAudioPCM(_ context: UnsafeMutableRawPointer, _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                    _ timestamp: UnsafePointer<AudioTimeStamp>, _ bus: UInt32, _ frames: UInt32,
                    _ buffers: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    guard let buffers else { return kAudio_ParamError }
    return context.assumingMemoryBound(to: AudioPCMQueue.self).pointee.render(frames: Int(frames), buffers: buffers)
}
