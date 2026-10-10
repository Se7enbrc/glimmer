// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AVFoundation
import CoreAudio
import Testing
@testable import Glimmer

@Suite(.serialized)
struct SpatialAudioTests {
    @Test func defaultStreamRetainsSurroundForLaterOutputChanges() {
        var config = StreamConfig(width: 1920, height: 1080, fps: 60, bitrateKbps: 20_000)
        #expect(config.audio == .surround71)
        config.audio = .surround51
        #expect(config.audio == .surround51)
        config.audio = .stereo
        #expect(config.audio == .stereo)
    }

    @Test func externalSpeakersAreNotTreatedAsHeadphones() {
        for transport in [kAudioDeviceTransportTypeUSB, kAudioDeviceTransportTypeBluetooth] {
            #expect(AudioOutputRoute.classify(transport: transport,
                                              terminals: [kAudioStreamTerminalTypeSpeaker]) == .other)
            #expect(AudioOutputRoute.classify(transport: transport,
                                              terminals: [kAudioStreamTerminalTypeHeadphones]) == .headphones)
        }
        #expect(AudioOutputRoute.classify(transport: nil, terminals: []) == .other)
        #expect(AudioOutputRoute.classify(transport: kAudioDeviceTransportTypeBuiltIn,
                                          terminals: [kAudioStreamTerminalTypeSpeaker]) == .builtInSpeakers)
    }

    @Test func rendererMatchesTheCurrentOutput() {
        #expect(AudioOutputRoute(kind: .headphones).spatialOutput(sourceChannels: 8) == .headphones)
        #expect(AudioOutputRoute(kind: .builtInSpeakers).spatialOutput(sourceChannels: 8) == .builtInSpeakers)
        #expect(AudioOutputRoute().spatialOutput(sourceChannels: 8) == .externalSpeakers)
        #expect(AudioOutputRoute(kind: .headphones).spatialOutput(sourceChannels: 2) == nil)
        for channels in [1, 4, 6, 8] {
            #expect(AudioOutputRoute(channels: channels, kind: .headphones).spatialOutput(sourceChannels: 8) == nil)
        }
    }

    @Test func ordinaryStereoDoesNotCreateASpatialMixer() throws {
        let decoder = AudioDecoder()
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        attachPlayer(decoder, format: format)
        decoder.connectOutputGraph(format: format, route: AudioOutputRoute(kind: .headphones))
        #expect(decoder.spatialMixer == nil)
        #expect(decoder.spatialOutputType == nil)
        #expect(decoder.engine.outputConnectionPoints(for: decoder.varispeed, outputBus: 0)
            .contains { $0.node === decoder.engine.mainMixerNode })
    }

    @Test(arguments: [6, 8])
    func everyChannelSurvivesSpeakerHeadphoneRoundTrip(channels: Int) throws {
        let format = try surroundFormat(channels: channels)
        let output = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        for source in 0..<channels {
            let decoder = AudioDecoder()
            defer { decoder.shutdown() }
            attachPlayer(decoder, format: format)
            decoder.connectOutputGraph(format: format, route: AudioOutputRoute())
            try decoder.engine.enableManualRenderingMode(.offline, format: output, maximumFrameCount: 512)
            let mixer = try #require(decoder.spatialMixer)
            for kind: AudioOutputRoute.Kind in [.other, .headphones, .other] {
                decoder.playerNode.stop()
                decoder.engine.stop()
                decoder.connectOutputGraph(format: format, route: AudioOutputRoute(kind: kind))
                #expect(decoder.spatialMixer === mixer)
                #expect(mixer.isListenerHeadTrackingEnabled == (kind == .headphones))
                #expect(mixer.outputType == (kind == .headphones ? .headphones : .externalSpeakers))
                let energy = try renderImpulse(decoder, format: format, output: output, source: source)
                #expect(energy.allSatisfy { $0.isFinite })
                #expect(energy.reduce(0, +) > 0.00001,
                        "Channel \(source) disappeared from \(channels)-channel audio on \(kind)")
                if source == 0 { #expect(energy[0] > energy[1]) }
                if source == 1 { #expect(energy[1] > energy[0]) }
            }
        }
    }

    @Test(arguments: [6, 8])
    func switchingToNativeSurroundBypassesSpatialProcessing(channels: Int) throws {
        let decoder = AudioDecoder()
        let format = try surroundFormat(channels: channels)
        attachPlayer(decoder, format: format)
        decoder.connectOutputGraph(format: format, route: AudioOutputRoute(kind: .headphones))
        let mixer = try #require(decoder.spatialMixer)
        #expect(decoder.spatialOutputType == .headphones)
        #expect(decoder.playerNode.sourceMode == .ambienceBed)
        #expect(mixer.isListenerHeadTrackingEnabled)
        decoder.connectOutputGraph(format: format, route: AudioOutputRoute(channels: channels))
        #expect(decoder.spatialOutputType == nil)
        #expect(decoder.playerNode.sourceMode == .bypass)
        #expect(!mixer.isListenerHeadTrackingEnabled)
        #expect(decoder.engine.outputConnectionPoints(for: decoder.varispeed, outputBus: 0)
            .contains { $0.node === decoder.engine.mainMixerNode })
        decoder.connectOutputGraph(format: format, route: AudioOutputRoute(kind: .headphones))
        #expect(decoder.spatialMixer === mixer)
        #expect(decoder.spatialOutputType == .headphones)
    }

    private func attachPlayer(_ decoder: AudioDecoder, format: AVAudioFormat) {
        decoder.engine.attach(decoder.playerNode)
        decoder.engine.attach(decoder.varispeed)
        decoder.engine.connect(decoder.playerNode, to: decoder.varispeed, format: format)
    }

    private func surroundFormat(channels: Int) throws -> AVAudioFormat {
        let tag = channels == 6 ? kAudioChannelLayoutTag_AudioUnit_5_1 : kAudioChannelLayoutTag_AudioUnit_7_1
        let layout = try #require(AVAudioChannelLayout(layoutTag: tag))
        return AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                             interleaved: false, channelLayout: layout)
    }

    private func renderImpulse(_ decoder: AudioDecoder, format: AVAudioFormat,
                               output: AVAudioFormat, source: Int) throws -> [Double] {
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 4_800))
        let data = try #require(pcm.floatChannelData)
        pcm.frameLength = 4_800
        for channel in 0..<Int(format.channelCount) { data[channel].update(repeating: 0, count: 4_800) }
        data[source][512] = 0.5
        try decoder.engine.start()
        decoder.playerNode.scheduleBuffer(pcm)
        decoder.playerNode.play()
        let rendered = try #require(AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 512))
        var energy = [Double](repeating: 0, count: 2)
        for _ in 0..<12 {
            let status = try decoder.engine.renderOffline(512, to: rendered)
            try #require(status == .success)
            let samples = try #require(rendered.floatChannelData)
            for channel in 0..<2 {
                for frame in 0..<Int(rendered.frameLength) {
                    energy[channel] += Double(samples[channel][frame] * samples[channel][frame])
                }
            }
        }
        return energy
    }
}
