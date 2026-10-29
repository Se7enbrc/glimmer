// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AVFAudio
import AudioToolbox
import GlimmerEngine

// Engine graph hooks serialize mutation; render pulls use only the engine's raw storage and C callbacks.
final class IOSAudioOutput {
    struct Calls {
        var create: (AudioComponentDescription) throws -> AudioUnit = { description in
            var description = description
            guard let component = AudioComponentFindNext(nil, &description) else {
                throw AudioOutput.Failure(status: kAudioUnitErr_InvalidProperty)
            }
            var unit: AudioUnit?
            let status = AudioComponentInstanceNew(component, &unit)
            guard status == noErr, let unit else {
                throw AudioOutput.Failure(status: status == noErr ? kAudioUnitErr_Uninitialized : status)
            }
            return unit
        }
        var set: (AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement,
                  UnsafeRawPointer, UInt32) -> OSStatus = AudioUnitSetProperty
        var get: (AudioUnit, AudioUnitPropertyID, AudioUnitScope, AudioUnitElement,
                  UnsafeMutableRawPointer, UnsafeMutablePointer<UInt32>) -> OSStatus = AudioUnitGetProperty
        var parameter: (AudioUnit, AudioUnitParameterID, AudioUnitScope, AudioUnitElement,
                        AudioUnitParameterValue, UInt32) -> OSStatus = AudioUnitSetParameter
        var initialize: (AudioUnit) -> OSStatus = AudioUnitInitialize
        var start: (AudioUnit) -> OSStatus = AudioOutputUnitStart
        var stop: (AudioUnit) -> OSStatus = AudioOutputUnitStop
        var uninitialize: (AudioUnit) -> OSStatus = AudioUnitUninitialize
        var dispose: (AudioUnit) -> OSStatus = AudioComponentInstanceDispose
    }

    let storage: AudioRenderStorage
    let session: IOSAudioSession
    let lease: IOSAudioSession.Lease
    let calls: Calls
    var units: [AudioUnit] = []
    var output: AudioUnit?
    var speed: AudioUnit?
    var mixer: AudioUnit?
    var sampleRate: Double = 0
    var channels: UInt32 = 0
    var latencyMs: Double = 0

    init(channels: Int, session: IOSAudioSession, lease: IOSAudioSession.Lease, calls: Calls = Calls()) {
        storage = AudioRenderStorage(channels: channels)
        self.session = session
        self.lease = lease
        self.calls = calls
    }

    deinit {
        storage.dispose { stop() }
        session.release()
    }

    var sharedOutput: AudioOutput {
        AudioOutput(storage: storage, sampleRate: sampleRate, channels: channels, latencyMs: latencyMs,
                    start: { self.start() }, isRunning: { self.isRunning },
                    setRate: { self.setRate($0) }, lastRenderError: { self.lastRenderError() })
    }

    func configure(format: AVAudioFormat) throws {
        let remote = try makeUnit(type: kAudioUnitType_Output, subtype: kAudioUnitSubType_RemoteIO)
        output = remote
        try set(remote, kAudioOutputUnitProperty_EnableIO, scope: kAudioUnitScope_Output, value: UInt32(1))
        let hardware: AudioStreamBasicDescription = try read(remote, kAudioUnitProperty_StreamFormat,
            scope: kAudioUnitScope_Output, initial: AudioStreamBasicDescription())
        // RemoteIO can report an unresolved zero rate before initialization on a real iPhone.
        // The active audio session already supplies the negotiated device rate.
        let outputRate = hardware.mSampleRate == 0 ? lease.route.sampleRate : hardware.mSampleRate
        guard outputRate.isFinite, outputRate > 0, hardware.mChannelsPerFrame > 0 else {
            throw AudioOutput.Failure(status: kAudioUnitErr_FormatNotSupported)
        }
        sampleRate = outputRate
        channels = min(2, hardware.mChannelsPerFrame)
        let maximum = max(4096, try read(remote, kAudioUnitProperty_MaximumFramesPerSlice, initial: UInt32(0)))
        let resampler = try makeUnit(type: kAudioUnitType_FormatConverter, subtype: kAudioUnitSubType_Varispeed)
        speed = resampler
        try set(resampler, kAudioUnitProperty_MaximumFramesPerSlice, value: maximum)
        try set(resampler, kAudioUnitProperty_SetRenderCallback, scope: kAudioUnitScope_Input,
                value: storage.renderCallback)
        try setFormat(resampler, scope: kAudioUnitScope_Input, rate: format.sampleRate, channels: format.channelCount)
        try setFormat(resampler, scope: kAudioUnitScope_Output, rate: sampleRate, channels: format.channelCount)
        let mix = try makeUnit(type: kAudioUnitType_Mixer, subtype: kAudioUnitSubType_MultiChannelMixer)
        mixer = mix
        try set(mix, kAudioUnitProperty_MaximumFramesPerSlice, value: maximum)
        try set(mix, kAudioUnitProperty_ElementCount, scope: kAudioUnitScope_Input, value: UInt32(1))
        try setFormat(mix, scope: kAudioUnitScope_Input, rate: sampleRate, channels: format.channelCount)
        try setFormat(mix, scope: kAudioUnitScope_Output, rate: sampleRate, channels: channels)
        try connect(resampler, to: mix)
        try check(calls.parameter(mix, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, 0, 1, 0))
        try check(calls.parameter(mix, kMultiChannelMixerParam_Volume, kAudioUnitScope_Output, 0, 1, 0))
        try setFormat(remote, scope: kAudioUnitScope_Input, rate: sampleRate, channels: channels)
        try connect(mix, to: remote)
        for unit in [resampler, mix, remote] { try check(calls.initialize(unit)) }
        let speedLatency = try read(resampler, kAudioUnitProperty_Latency, initial: Float64(0))
        let mixerLatency = try read(mix, kAudioUnitProperty_Latency, initial: Float64(0))
        guard speedLatency.isFinite, speedLatency >= 0, mixerLatency.isFinite, mixerLatency >= 0 else {
            throw AudioOutput.Failure(status: kAudioUnitErr_InvalidPropertyValue)
        }
        // Session latency is hardware delay; add one output quantum and only our processing units.
        // RemoteIO's unit latency is excluded so its device/buffer delay cannot be counted twice.
        latencyMs = (lease.route.latency + lease.route.bufferDuration + speedLatency + mixerLatency) * 1000
    }

    func start() -> OSStatus {
        session.withPlayback(generation: lease.generation, unavailable: kAudioUnitErr_CannotDoInCurrentContext) {
            guard let output else { return kAudioUnitErr_Uninitialized }
            return calls.start(output)
        }
    }

    var isRunning: Bool {
        session.withPlayback(generation: lease.generation, unavailable: false) {
            guard let output else { return false }
            let running = try? read(output, kAudioOutputUnitProperty_IsRunning, initial: UInt32(0))
            return running.map { $0 != 0 } ?? false
        }
    }

    func setRate(_ value: Float) -> OSStatus {
        guard let speed else { return kAudioUnitErr_Uninitialized }
        return calls.parameter(speed, kVarispeedParam_PlaybackRate, kAudioUnitScope_Global, 0, value, 0)
    }

    func lastRenderError() -> OSStatus {
        guard let mixer else { return kAudioUnitErr_Uninitialized }
        do {
            return try read(mixer, kAudioUnitProperty_LastRenderError, initial: OSStatus(noErr))
        } catch let failure as AudioOutput.Failure {
            return failure.status
        } catch {
            return kAudioUnitErr_Uninitialized
        }
    }

    private func stop() -> Bool {
        if let output { report(calls.stop(output)) }
        // Dispose the reader first. A surviving unit must never pull through an already freed upstream unit.
        let order = [output].compactMap { $0 } + units.reversed().filter { $0 != output }
        for unit in order {
            report(calls.uninitialize(unit))
            let status = calls.dispose(unit)
            report(status)
            guard status == noErr else { return false }
        }
        return true
    }

    private func report(_ status: OSStatus) {
        if status != noErr { IOSAudioSession.log.error("audio unit teardown failed (OSStatus \(status))") }
    }
}
