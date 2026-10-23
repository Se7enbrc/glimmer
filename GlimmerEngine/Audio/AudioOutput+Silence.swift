// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AudioToolbox
import Foundation
import Synchronization

// One render thread owns each probe; the maintenance queue requests and drains it through atomics.
// Only the requested quantum scans samples, once per second, without allocation or logging.
struct AudioOutputProbe: ~Copyable {
    enum Result: Int { case pending, flowingOrIdle, silent, failed }

    let requested = Atomic<Bool>(false)
    let active = Atomic<Bool>(false)
    let inputAudible = Atomic<Bool>(false)
    let result = Atomic<Int>(0)

    func reset() {
        requested.store(false, ordering: .relaxed)
        active.store(false, ordering: .relaxed)
        inputAudible.store(false, ordering: .relaxed)
        result.store(0, ordering: .relaxed)
    }

    func begin() {
        guard requested.exchange(false, ordering: .acquiring) else { return }
        inputAudible.store(false, ordering: .relaxed)
        active.store(true, ordering: .relaxed)
    }

    func captureInput(_ buffers: UnsafeMutablePointer<AudioBufferList>, frames: UInt32) {
        guard active.load(ordering: .relaxed), hasSignal(buffers, frames: frames) else { return }
        inputAudible.store(true, ordering: .relaxed)
    }

    func finish(_ buffers: UnsafeMutablePointer<AudioBufferList>?, frames: UInt32,
                failed: Bool, isSilence: Bool = false) {
        guard active.exchange(false, ordering: .relaxed) else { return }
        let signal = !failed && !isSilence && (buffers.map { hasSignal($0, frames: frames) } ?? false)
        let silent = inputAudible.load(ordering: .relaxed) && !signal
        let value: Result = failed ? .failed : (silent ? .silent : .flowingOrIdle)
        result.store(value.rawValue, ordering: .releasing)
    }

    private func hasSignal(_ buffers: UnsafeMutablePointer<AudioBufferList>, frames: UInt32) -> Bool {
        let offset = MemoryLayout<AudioBufferList>.size - MemoryLayout<AudioBuffer>.size
        let data = UnsafeMutableRawPointer(buffers).advanced(by: offset).assumingMemoryBound(to: AudioBuffer.self)
        var channel = 0
        while channel < Int(buffers.pointee.mNumberBuffers) {
            if let pointer = data[channel].mData {
                let samples = pointer.assumingMemoryBound(to: Float.self)
                let count = min(Int(frames), Int(data[channel].mDataByteSize) / MemoryLayout<Float>.size)
                var frame = 0
                while frame < count {
                    if abs(samples[frame]) > 0.00001 { return true }
                    frame &+= 1
                }
            }
            channel &+= 1
        }
        return false
    }
}

func observeAudioOutput(_ context: UnsafeMutableRawPointer,
                        _ flags: UnsafeMutablePointer<AudioUnitRenderActionFlags>,
                        _ timestamp: UnsafePointer<AudioTimeStamp>, _ bus: UInt32, _ frames: UInt32,
                        _ buffers: UnsafeMutablePointer<AudioBufferList>?) -> OSStatus {
    let queue = context.assumingMemoryBound(to: AudioPCMQueue.self)
    if flags.pointee.contains(.unitRenderAction_PreRender) { queue.pointee.outputProbe.begin() }
    if flags.pointee.contains(.unitRenderAction_PostRender) {
        let failed = flags.pointee.contains(.unitRenderAction_PostRenderError)
        queue.pointee.outputProbe.finish(buffers, frames: frames, failed: failed,
                                        isSilence: flags.pointee.contains(.unitRenderAction_OutputIsSilence))
    }
    return noErr
}

struct AudioOutputSilence {
    init() {}

    var lastObservation: UInt64 = 0
    var seconds: Double = 0
    private var wasSilent = false
    private var reported = false

    mutating func observe(result: AudioOutputProbe.Result, elapsed: Double, log: (String) -> Void) {
        let silent = result == .silent && elapsed <= 2
        seconds = silent && wasSilent ? seconds + elapsed : 0
        wasSilent = silent
        if seconds >= 1, !reported {
            log("audio output silent while nonzero PCM is consumed")
            reported = true
        } else if !silent {
            reported = false
        }
    }
}

extension AudioOutput {
    func observeOutputSilence(now: UInt64 = DispatchTime.now().uptimeNanoseconds,
                              telemetry: AudioPipelineTelemetry = .shared,
                              log: (String) -> Void = { Diag.error("\($0)", "Stream.Audio") }) {
        let elapsed = Double(now &- outputSilence.lastObservation) / 1_000_000_000
        guard elapsed >= 1 else { return }
        let raw = queue.pointee.outputProbe.result.exchange(0, ordering: .acquiringAndReleasing)
        let result = AudioOutputProbe.Result(rawValue: raw) ?? .pending
        telemetry.noteOutputProbe(result: result.rawValue, inputAudible: result == .pending ? nil
            : queue.pointee.outputProbe.inputAudible.load(ordering: .relaxed))
        outputSilence.observe(result: result, elapsed: elapsed, log: log)
        outputSilence.lastObservation = now
        telemetry.noteOutputSilence(seconds: outputSilence.seconds)
        if result == .failed {
            log("audio output render failed (OSStatus \(lastRenderError()))")
        }
        queue.pointee.outputProbe.requested.store(true, ordering: .releasing)
    }
}
