// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AVFAudio
import AudioToolbox

extension AudioHALOutput {
    // Apple's ambience-bed pull graph preserves speaker directions and delegates head pose to the mixer.
    // https://developer.apple.com/documentation/audiotoolbox/generating-spatial-audio-from-a-multichannel-audio-stream
    func spatialSource(_ source: AudioUnit, format: AVAudioFormat, route: AudioOutputRoute) throws -> AudioUnit {
        guard let outputType = route.spatialOutput(sourceChannels: Int(format.channelCount)) else {
            Diag.info("Audio output: native, \(format.channelCount) source channels", "Stream.Audio")
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
        Diag.info("Audio output: spatial, \(format.channelCount) source channels, "
            + "head tracking \(headTracking)", "Stream.Audio")
        return mixer
    }
}
