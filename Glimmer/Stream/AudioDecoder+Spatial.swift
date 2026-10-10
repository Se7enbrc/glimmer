// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AVFoundation

extension AudioDecoder {
    /// The caller holds `stateLock` and catches Objective-C exceptions around graph changes.
    func connectOutputGraph(format: AVAudioFormat, route: AudioOutputRoute) {
        let output = route.spatialOutput(sourceChannels: Int(format.channelCount))
        outputGraphNeedsReconnect = true
        engine.disconnectNodeOutput(varispeed)
        if let spatialMixer { engine.disconnectNodeOutput(spatialMixer) }
        guard let output else {
            playerNode.sourceMode = .bypass
            if let spatialMixer { spatialMixer.isListenerHeadTrackingEnabled = false }
            engine.connect(varispeed, to: engine.mainMixerNode, format: format)
            spatialOutputType = nil
            outputGraphNeedsReconnect = false
            Diag.info("Audio output: native, \(format.channelCount) source channels", "Stream.Audio")
            return
        }
        let mixer: AVAudioEnvironmentNode
        if let spatialMixer {
            mixer = spatialMixer
        } else {
            mixer = AVAudioEnvironmentNode()
            engine.attach(mixer)
            spatialMixer = mixer
        }
        mixer.outputType = output
        mixer.reverbParameters.enable = false
        mixer.isListenerHeadTrackingEnabled = output == .headphones
        let stereo = AVAudioFormat(standardFormatWithSampleRate: format.sampleRate, channels: 2)
        engine.connect(varispeed, to: mixer, format: format)
        engine.connect(mixer, to: engine.mainMixerNode, format: stereo)
        playerNode.sourceMode = .ambienceBed
        playerNode.renderingAlgorithm = .auto
        spatialOutputType = output
        outputGraphNeedsReconnect = false
        let renderer: String = switch output {
        case .headphones: "headphones"
        case .builtInSpeakers: "built-in speakers"
        default: "external speakers"
        }
        Diag.info("Audio output: \(renderer), \(format.channelCount) source channels, "
            + "head tracking \(mixer.isListenerHeadTrackingEnabled)", "Stream.Audio")
    }
}
