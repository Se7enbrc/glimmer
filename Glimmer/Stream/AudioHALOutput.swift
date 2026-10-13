// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import AVFAudio
import AudioToolbox
import CoreAudio

// Lifecycle is serialized by AudioDecoder's graph gate; the callback receives only the raw queue pointer.
final class AudioHALOutput {
    struct Failure: Error { let status: OSStatus; var property: AudioUnitPropertyID = 0 }
    private(set) var units: [AudioUnit] = []
    private(set) var output: AudioUnit?
    private(set) var speed: AudioUnit?
    var isRunning: Bool {
        guard let output else { return false }
        var running: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioUnitGetProperty(output, kAudioOutputUnitProperty_IsRunning, kAudioUnitScope_Global,
                                   0, &running, &size) == noErr, running != 0 else { return false }
        let deviceRunning = try? AudioHALDevice.read(device,
            selector: kAudioDevicePropertyDeviceIsRunningSomewhere, initial: UInt32(0))
        return deviceRunning != nil && deviceRunning != 0
    }
    private(set) var device: AudioDeviceID = 0
    private(set) var sampleRate: Double = 0
    private(set) var channels: UInt32 = 0
    private(set) var latencyMs: Double = 0
    var spatial = false
    var outputSilence = AudioOutputSilence()
    let queue: UnsafeMutablePointer<AudioPCMQueue>

    init(channels: Int, capacity: Int = 48_000) {
        queue = .allocate(capacity: 1)
        queue.initialize(to: AudioPCMQueue(capacity: capacity, channels: channels))
    }

    deinit {
        guard stop() else {
            Diag.error("audio unit disposal failed; retaining callback storage", "Stream.Audio")
            return
        }
        queue.deinitialize(count: 1)
        queue.deallocate()
    }

    func configure(format: AVAudioFormat, route: AudioOutputRoute,
                   hardware: () throws -> AudioHALDevice = { try AudioHALDevice.current() },
                   connectHardware: Bool = true) throws {
        guard stop() else { throw Failure(status: kAudioUnitErr_CannotDoInCurrentContext) }
        spatial = false
        outputSilence = AudioOutputSilence()
        queue.pointee.outputProbe.reset()
        do {
            let hardware = try hardware()
            device = hardware.id
            sampleRate = hardware.rate
            channels = UInt32(AudioHALDevice.outputChannels(source: Int(format.channelCount), route: route))
            latencyMs = hardware.latencyMs
            let hal: AudioUnit?
            if connectHardware {
                let unit = try makeUnit(type: kAudioUnitType_Output, subtype: kAudioUnitSubType_HALOutput)
                try set(unit, kAudioOutputUnitProperty_CurrentDevice, value: device)
                hal = unit
            } else {
                hal = nil
            }
            output = hal
            let resampler = try makeUnit(type: kAudioUnitType_FormatConverter, subtype: kAudioUnitSubType_Varispeed)
            speed = resampler
            var callback = AURenderCallbackStruct(inputProc: renderAudioPCM, inputProcRefCon: queue)
            try check(AudioUnitSetProperty(resampler, kAudioUnitProperty_SetRenderCallback, kAudioUnitScope_Input,
                                           0, &callback, UInt32(MemoryLayout<AURenderCallbackStruct>.size)))
            try setFormat(resampler, scope: kAudioUnitScope_Input, rate: format.sampleRate,
                          channels: format.channelCount, layout: nil)
            try setFormat(resampler, scope: kAudioUnitScope_Output, rate: sampleRate,
                          channels: format.channelCount, layout: nil)
            let source = try spatialSource(resampler, format: format, route: route)
            let mixer = try makeUnit(type: kAudioUnitType_Mixer, subtype: kAudioUnitSubType_MultiChannelMixer)
            try set(mixer, kAudioUnitProperty_ElementCount, scope: kAudioUnitScope_Input, value: UInt32(1))
            let sourceChannels = spatial ? 2 : format.channelCount
            try setFormat(mixer, scope: kAudioUnitScope_Input, rate: sampleRate, channels: sourceChannels,
                          layout: spatial ? kAudioChannelLayoutTag_Stereo : format.channelLayout?.layoutTag)
            try setFormat(mixer, scope: kAudioUnitScope_Output, rate: sampleRate, channels: channels,
                          layout: AudioHALDevice.layout(channels: channels))
            // HAL's stereo map owns device positions; unknown speaker labels would silence the mixer.
            if channels != 2, let layout = hardware.channelLayout, layout.channelCount == channels {
                try setChannelLayout(mixer, scope: kAudioUnitScope_Output, layout: layout)
            }
            try connect(source, to: mixer)
            try check(AudioUnitSetParameter(mixer, kMultiChannelMixerParam_Volume, kAudioUnitScope_Input, 0, 1, 0))
            try check(AudioUnitSetParameter(mixer, kMultiChannelMixerParam_Volume, kAudioUnitScope_Output, 0, 1, 0))
            try configureBuiltInDownmix(mixer, format: format, route: route)
            try check(AudioUnitAddRenderNotify(mixer, observeAudioOutput, queue))
            if let hal {
                try setFormat(hal, scope: kAudioUnitScope_Input, rate: sampleRate, channels: channels, layout: nil)
                if channels == 2 { try configureStereoMap(hal) }
                try connect(mixer, to: hal)
            }
            for unit in units where unit != hal { try check(AudioUnitInitialize(unit)) }
            if let hal { try check(AudioUnitInitialize(hal)) }
        } catch {
            stop()
            throw error
        }
    }

    private func configureStereoMap(_ hal: AudioUnit) throws {
        var format = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        try check(AudioUnitGetProperty(hal, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output,
                                       0, &format, &size))
        let preferred = try AudioHALDevice.read(device, selector: kAudioDevicePropertyPreferredChannelsForStereo,
            scope: kAudioDevicePropertyScopeOutput, initial: (UInt32(1), UInt32(2)))
        let map = try AudioHALDevice.stereoChannelMap(channels: Int(format.mChannelsPerFrame), preferred: preferred)
        try map.withUnsafeBufferPointer {
            try check(AudioUnitSetProperty(hal, kAudioOutputUnitProperty_ChannelMap, kAudioUnitScope_Output,
                                           0, $0.baseAddress, UInt32($0.count * MemoryLayout<Int32>.size)))
        }
    }

    func start() -> OSStatus {
        guard let output else { return kAudioUnitErr_Uninitialized }
        return AudioOutputUnitStart(output)
    }

    @discardableResult
    func stop(stopOutput: (AudioUnit) -> OSStatus = AudioOutputUnitStop,
              uninitialize: (AudioUnit) -> OSStatus = AudioUnitUninitialize,
              dispose: (AudioUnit) -> OSStatus = AudioComponentInstanceDispose) -> Bool {
        queue.pointee.enabled.store(false, ordering: .releasing)
        if let output { reportTeardownStatus(stopOutput(output)) }
        // HAL must stop before downstream readers are disposed. A failed dispose keeps its callback storage alive.
        let order = [output].compactMap({ $0 }) + units.reversed().filter({ $0 != output })
        for unit in order {
            reportTeardownStatus(uninitialize(unit))
            let status = dispose(unit)
            reportTeardownStatus(status)
            guard status == noErr else { return false }
            units.removeAll { $0 == unit }
            if output == unit { output = nil }
            if speed == unit { speed = nil }
        }
        return true
    }

    private func reportTeardownStatus(_ status: OSStatus) {
        if status != noErr { Diag.error("audio unit teardown (OSStatus \(status))", "Stream.Audio") }
    }

    func setRate(_ rate: Float) -> OSStatus {
        guard let speed else { return kAudioUnitErr_Uninitialized }
        return AudioUnitSetParameter(speed, kVarispeedParam_PlaybackRate, kAudioUnitScope_Global, 0, rate, 0)
    }

    func makeUnit(type: OSType, subtype: OSType) throws -> AudioUnit {
        var description = AudioComponentDescription(componentType: type, componentSubType: subtype,
            componentManufacturer: kAudioUnitManufacturer_Apple, componentFlags: 0, componentFlagsMask: 0)
        guard let component = AudioComponentFindNext(nil, &description) else {
            throw Failure(status: kAudioUnitErr_InvalidProperty)
        }
        var instance: AudioUnit?
        try check(AudioComponentInstanceNew(component, &instance))
        guard let instance else { throw Failure(status: kAudioUnitErr_Uninitialized) }
        units.append(instance)
        try set(instance, kAudioUnitProperty_MaximumFramesPerSlice, value: UInt32(4096))
        return instance
    }

    func set<T>(_ unit: AudioUnit, _ property: AudioUnitPropertyID,
                scope: AudioUnitScope = kAudioUnitScope_Global, value: T) throws {
        var value = value
        let status = withUnsafePointer(to: &value) {
            AudioUnitSetProperty(unit, property, scope, 0, $0, UInt32(MemoryLayout<T>.size))
        }
        if status != noErr { throw Failure(status: status, property: property) }
    }

    func setFormat(_ unit: AudioUnit, scope: AudioUnitScope, rate: Double,
                   channels: UInt32, layout: AudioChannelLayoutTag?) throws {
        let format = AudioStreamBasicDescription(mSampleRate: rate, mFormatID: kAudioFormatLinearPCM,
            mFormatFlags: kAudioFormatFlagsNativeFloatPacked | kAudioFormatFlagIsNonInterleaved,
            mBytesPerPacket: 4, mFramesPerPacket: 1, mBytesPerFrame: 4, mChannelsPerFrame: channels,
            mBitsPerChannel: 32, mReserved: 0)
        try set(unit, kAudioUnitProperty_StreamFormat, scope: scope, value: format)
        if let layout {
            var channelLayout = AudioChannelLayout()
            channelLayout.mChannelLayoutTag = layout
            try set(unit, kAudioUnitProperty_AudioChannelLayout, scope: scope, value: channelLayout)
        }
    }

    func setChannelLayout(_ unit: AudioUnit, scope: AudioUnitScope, layout: AVAudioChannelLayout) throws {
        let descriptions = Int(layout.layout.pointee.mNumberChannelDescriptions)
        let size = 3 * MemoryLayout<UInt32>.size + descriptions * MemoryLayout<AudioChannelDescription>.size
        try check(AudioUnitSetProperty(unit, kAudioUnitProperty_AudioChannelLayout, scope, 0,
                                       layout.layout, UInt32(size)))
    }

    func connect(_ source: AudioUnit, to destination: AudioUnit) throws {
        let connection = AudioUnitConnection(sourceAudioUnit: source, sourceOutputNumber: 0, destInputNumber: 0)
        try set(destination, kAudioUnitProperty_MakeConnection, scope: kAudioUnitScope_Input, value: connection)
    }

    func check(_ status: OSStatus) throws {
        if status != noErr { throw Failure(status: status) }
    }
}
