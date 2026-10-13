// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import AVFAudio
import AudioToolbox

extension AudioHALOutput {
    // Apple's ambience-bed pull graph preserves speaker directions and delegates head pose to the mixer.
    // https://developer.apple.com/documentation/audiotoolbox/generating-spatial-audio-from-a-multichannel-audio-stream
    func spatialSource(_ source: AudioUnit, format: AVAudioFormat, route: AudioOutputRoute) throws -> AudioUnit {
        guard let outputType = route.spatialOutput(sourceChannels: Int(format.channelCount)) else {
            let path = route.kind == .builtInSpeakers && format.channelCount > 2 && route.channels == 2
                ? "stereo downmix, built-in speakers, LFE included" : "native"
            Diag.info("Audio output: \(path), \(format.channelCount) source channels", "Stream.Audio")
            return source
        }
        let headTracking = outputType == .spatialMixerOutputType_Headphones
        let mixer = try makeUnit(type: kAudioUnitType_Mixer, subtype: kAudioUnitSubType_SpatialMixer)
        try setFormat(mixer, scope: kAudioUnitScope_Input, rate: sampleRate, channels: format.channelCount,
                      layout: format.channelLayout?.layoutTag)
        try setFormat(mixer, scope: kAudioUnitScope_Output, rate: sampleRate, channels: 2,
                      layout: kAudioChannelLayoutTag_Stereo)
        try set(mixer, kAudioUnitProperty_SpatializationAlgorithm, scope: kAudioUnitScope_Input,
                value: AUSpatializationAlgorithm.spatializationAlgorithm_UseOutputType.rawValue)
        try set(mixer, kAudioUnitProperty_SpatialMixerSourceMode, scope: kAudioUnitScope_Input,
                value: AUSpatialMixerSourceMode.spatialMixerSourceMode_AmbienceBed.rawValue)
        try set(mixer, kAudioUnitProperty_SpatialMixerOutputType, value: outputType.rawValue)
        try set(mixer, kAudioUnitProperty_UsesInternalReverb, value: UInt32(0))
        try set(mixer, kAudioUnitProperty_SpatialMixerPersonalizedHRTFMode,
                value: AUSpatialMixerPersonalizedHRTFMode.auto.rawValue)
        try set(mixer, kAudioUnitProperty_SpatialMixerEnableHeadTracking,
                value: UInt32(headTracking ? 1 : 0))
        try connect(source, to: mixer)
        spatial = true
        Diag.info("Audio output: spatial type \(outputType.rawValue), \(format.channelCount) source channels, "
            + "head tracking \(headTracking)", "Stream.Audio")
        return mixer
    }

    func configureBuiltInDownmix(_ mixer: AudioUnit, format: AVAudioFormat, route: AudioOutputRoute) throws {
        guard route.kind == .builtInSpeakers, route.channels == 2, format.channelCount > 2 else { return }
        guard [6, 8].contains(format.channelCount),
              format.channelLayout?.layoutTag == AudioHALDevice.layout(channels: format.channelCount) else {
            throw Failure(status: kAudioUnitErr_FormatNotSupported)
        }
        // Preserve center, LFE and both surround pairs, with equal headroom for correlated full-scale channels.
        let surround: Float = sqrt(0.5)
        var levels: [Float] = [1, 0, 0, 1, surround, surround, 0.5, 0.5, surround, 0, 0, surround]
        if format.channelCount == 8 { levels += [surround, 0, 0, surround] }
        let gain: Float = 1 / (1.5 + surround * (format.channelCount == 8 ? 3 : 2))
        levels = levels.map { $0 * gain }
        try levels.withUnsafeBufferPointer {
            try check(AudioUnitSetProperty(mixer, kAudioUnitProperty_MatrixLevels, kAudioUnitScope_Input,
                                           0, $0.baseAddress, UInt32($0.count * MemoryLayout<Float>.size)))
        }
    }
}
