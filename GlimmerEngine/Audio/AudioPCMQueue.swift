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
    let fadingOut = Atomic<Bool>(false)
    let fadeGain = Atomic<Float>(1)
    let firstRenderHostTime = Atomic<UInt64>(0)
    let lastRenderHostTime = Atomic<UInt64>(0)
    #if os(macOS)
    let outputProbe = AudioOutputProbe()
    #endif
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

    func render(frames: Int, buffers: UnsafeMutablePointer<AudioBufferList>, hostTime: UInt64 = 0) -> OSStatus {
        // AudioBuffer byte counts are UInt32; reject oversized requests before any pointer arithmetic.
        guard frames >= 0, frames <= 1_073_741_823 else { return kAudio_ParamError }
        guard Int(buffers.pointee.mNumberBuffers) == channels else { return kAudioUnitErr_FormatNotSupported }
        let offset = MemoryLayout<AudioBufferList>.size - MemoryLayout<AudioBuffer>.size
        let output = UnsafeMutableRawPointer(buffers).advanced(by: offset).assumingMemoryBound(to: AudioBuffer.self)
        var channel = 0
        while channel < channels {
            guard output[channel].mData != nil,
                  Int(output[channel].mDataByteSize) >= frames &* MemoryLayout<Float>.size else {
                return kAudioUnitErr_TooManyFramesToProcess
            }
            channel &+= 1
        }
        // Capacity is positive at construction; nontrapping arithmetic keeps Debug free of runtime slow paths.
        let ringCapacity = UInt64(truncatingIfNeeded: capacity)
        let start = consumed.load(ordering: .relaxed)
        let end = written.load(ordering: .acquiring)
        let active = enabled.load(ordering: .acquiring)
        let available = Int(truncatingIfNeeded: end &- start)
        let count = active ? (frames < available ? frames : available) : 0
        let hasGain = !muted.load(ordering: .relaxed)
            && (fadeGain.load(ordering: .relaxed) > 0 || !fadingOut.load(ordering: .acquiring))
        renderSamples(output, start: start, count: count, frames: frames)
        guard active else { return 0 }
        if count > 0 {
            if hostTime > 0, hasGain {
                if firstRenderHostTime.load(ordering: .relaxed) == 0 {
                    firstRenderHostTime.store(hostTime, ordering: .relaxed)
                }
                lastRenderHostTime.store(hostTime, ordering: .relaxed)
            }
        }
        var silent: UInt64 = 0
        var frame = 0
        while frame < count {
            let position = start &+ UInt64(truncatingIfNeeded: frame)
            let remainder = position.remainderReportingOverflow(dividingBy: ringCapacity).partialValue
            let slot = Int(truncatingIfNeeded: remainder)
            silent &+= UInt64(silence[slot])
            frame &+= 1
        }
        observationVersion.wrappingAdd(1, ordering: .acquiringAndReleasing)
        silenceConsumed.wrappingAdd(silent, ordering: .relaxed)
        consumed.store(start &+ UInt64(truncatingIfNeeded: count), ordering: .releasing)
        minimumFill.min(Int(truncatingIfNeeded: end &- start) &- count, ordering: .relaxed)
        if count < frames {
            if !drained.exchange(true, ordering: .relaxed) { underruns.wrappingAdd(1, ordering: .releasing) }
        } else {
            drained.store(false, ordering: .relaxed)
        }
        observationVersion.wrappingAdd(1, ordering: .releasing)
        return 0
    }

    private func renderSamples(_ output: UnsafeMutablePointer<AudioBuffer>, start: UInt64, count: Int, frames: Int) {
        let ringCapacity = UInt64(truncatingIfNeeded: capacity)
        let gain: Float = muted.load(ordering: .relaxed) ? 0 : 1
        let initialGain = fadeGain.load(ordering: .relaxed)
        let targetGain: Float = fadingOut.load(ordering: .acquiring) ? 0 : 1
        let step: Float = targetGain < initialGain ? -1 / 240 : 1 / 240
        var channel = 0
        while channel < channels {
            if let pointer = output[channel].mData {
                let data = pointer.assumingMemoryBound(to: Float.self)
                var frame = 0
                while frame < count {
                    let position = start &+ UInt64(truncatingIfNeeded: frame)
                    let slot = Int(truncatingIfNeeded: position.remainderReportingOverflow(dividingBy: ringCapacity)
                        .partialValue)
                    let ramp = initialGain == targetGain ? targetGain
                        : min(1, max(0, initialGain + Float(frame &+ 1) * step))
                    data[frame] = samples[channel &* capacity &+ slot] * gain * ramp
                    frame &+= 1
                }
                while frame < frames {
                    data[frame] = 0
                    frame &+= 1
                }
            }
            channel &+= 1
        }
        fadeGain.store(initialGain == targetGain ? targetGain
            : min(1, max(0, initialGain + Float(count) * step)), ordering: .relaxed)
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
    let queue = context.assumingMemoryBound(to: AudioPCMQueue.self)
    let hostTime = timestamp.pointee.mFlags.contains(.hostTimeValid)
        ? timestamp.pointee.mHostTime : 0
    let status = queue.pointee.render(frames: Int(frames), buffers: buffers, hostTime: hostTime)
    #if os(macOS)
    if status == noErr { queue.pointee.outputProbe.captureInput(buffers, frames: frames) }
    #endif
    return status
}
