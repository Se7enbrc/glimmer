// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AVFoundation
import AudioToolbox
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
        #expect(AudioOutputRoute(kind: .headphones).spatialOutput(sourceChannels: 8)
            == .spatialMixerOutputType_Headphones)
        #expect(AudioOutputRoute(kind: .builtInSpeakers).spatialOutput(sourceChannels: 8)
            == .spatialMixerOutputType_BuiltInSpeakers)
        #expect(AudioOutputRoute().spatialOutput(sourceChannels: 8) == .spatialMixerOutputType_ExternalSpeakers)
        #expect(AudioOutputRoute(kind: .headphones).spatialOutput(sourceChannels: 2) == nil)
        for channels in [1, 4, 6, 8] {
            #expect(AudioOutputRoute(channels: channels, kind: .headphones).spatialOutput(sourceChannels: 8) == nil)
        }
    }

    @Test(arguments: [2, 6, 8])
    func nativeOutputsPreserveChannelIdentity(channels: Int) throws {
        let route = AudioOutputRoute(channels: channels)
        #expect(AudioHALDevice.outputChannels(source: channels, route: route) == channels)
        for source in 0..<channels {
            let energy = try renderImpulse(channels: channels, route: route, source: source)
            for destination in 0..<channels {
                #expect(destination == source ? energy[destination] > 0.001 : energy[destination] < 0.000001)
            }
        }
    }

    @Test(arguments: [6, 8])
    func spatialRendererRetainsEveryChannelIncludingLFE(channels: Int) throws {
        for kind: AudioOutputRoute.Kind in [.other, .headphones] {
            for source in 0..<channels {
                let energy = try renderImpulse(channels: channels, route: AudioOutputRoute(kind: kind), source: source)
                #expect(energy.allSatisfy { $0.isFinite })
                #expect(energy.reduce(0, +) > 0.000001,
                        "Channel \(source) disappeared from \(channels)-channel audio on \(kind)")
            }
        }
    }

    @Test(arguments: [44_100.0, 96_000.0])
    func outputSampleRateConversionPreservesAudiblePCM(rate: Double) throws {
        let energy = try renderImpulse(channels: 2, route: AudioOutputRoute(), source: 0, outputRate: rate)
        #expect(energy[0] > 0.001)
        #expect(energy[1] < 0.000001)
    }

    @Test func preferredSpeakerOrderMapsCenterAndLFE() throws {
        let layout = try #require(AVAudioChannelLayout(layoutTag: kAudioChannelLayoutTag_MPEG_5_1_B))
        for (source, destination) in [(2, 4), (3, 5), (4, 2), (5, 3)] {
            let energy = try renderImpulse(channels: 6, route: AudioOutputRoute(channels: 6), source: source,
                                           preferredLayout: layout)
            #expect(energy[destination] > 0.001)
            #expect(energy.enumerated().filter { $0.offset != destination }.allSatisfy { $0.element < 0.000001 })
        }
    }

    @Test func teardownDisposesReadersBeforeSourcesAndRetainsFailedDisposals() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let graph = AudioHALOutput(channels: 2)
        try graph.configure(format: format, route: AudioOutputRoute(),
                            hardware: { AudioHALDevice(id: 0, rate: 48_000, latencyMs: 0) }, connectHardware: false)
        let order = Array(graph.units.reversed())
        graph.queue.pointee.enabled.store(true, ordering: .releasing)
        var attempted: [AudioUnit] = []
        let failed = graph.stop(dispose: { unit in
            #expect(Bool(!graph.queue.pointee.enabled.load(ordering: .acquiring)))
            attempted.append(unit)
            return kAudioUnitErr_CannotDoInCurrentContext
        })
        #expect(!failed)
        #expect(attempted == Array(order.prefix(1)))
        #expect(graph.units.count == order.count)
        attempted.removeAll()
        let stopped = graph.stop(dispose: { unit in
            attempted.append(unit)
            return AudioComponentInstanceDispose(unit)
        })
        #expect(stopped)
        #expect(attempted == order)
        #expect(graph.units.isEmpty)
    }

    @Test func unavailableDeviceLeavesNoPartialGraph() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let graph = AudioHALOutput(channels: 2)
        do {
            try graph.configure(format: format, route: AudioOutputRoute(), hardware: {
                throw AudioHALOutput.Failure(status: kAudioHardwareBadDeviceError)
            })
            Issue.record("An unavailable device must reject setup")
        } catch let failure as AudioHALOutput.Failure {
            #expect(failure.status == kAudioHardwareBadDeviceError)
        }
        #expect(graph.units.isEmpty)
        #expect(!graph.isRunning)
    }

    @Test func softwareGraphNegotiatesFormatAndRejectsInvalidProperties() throws {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2))
        let graph = AudioHALOutput(channels: 2)
        #expect(graph.start() == kAudioUnitErr_Uninitialized)
        #expect(graph.setRate(1) == kAudioUnitErr_Uninitialized)
        try graph.configure(format: format, route: .init(),
                            hardware: { AudioHALDevice(id: 42, rate: 96_000, latencyMs: 7.5) }, connectHardware: false)
        #expect(graph.device == 42 && graph.sampleRate == 96_000 && graph.latencyMs == 7.5)
        #expect(graph.channels == 2 && !graph.spatial && !graph.isRunning)
        #expect(graph.setRate(1.001) == noErr)
        let unit = try #require(graph.speed)
        var output = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        #expect(AudioUnitGetProperty(unit, kAudioUnitProperty_StreamFormat, kAudioUnitScope_Output,
                                     0, &output, &size) == noErr)
        #expect(output.mSampleRate == 96_000 && output.mChannelsPerFrame == 2)
        #expect(output.mBitsPerChannel == 32 && output.mBytesPerFrame == 4)
        #expect(output.mFormatFlags & kAudioFormatFlagIsNonInterleaved != 0)
        do {
            try graph.set(unit, UInt32.max, value: UInt32(0))
            Issue.record("An unknown property must fail")
        } catch let failure as AudioHALOutput.Failure {
            #expect(failure.property == UInt32.max && failure.status != noErr)
        }
        #expect(throws: AudioHALOutput.Failure.self) { try graph.makeUnit(type: 0, subtype: 0) }
        #expect(graph.stop())
        #expect(graph.units.isEmpty && graph.speed == nil)
    }

    private func renderImpulse(channels: Int, route: AudioOutputRoute, source: Int,
                               outputRate: Double = 48_000,
                               preferredLayout: AVAudioChannelLayout? = nil) throws -> [Double] {
        let layout = try #require(AVAudioChannelLayout(layoutTag: AudioHALDevice.layout(channels: UInt32(channels))))
        let format = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000,
                                   interleaved: false, channelLayout: layout)
        let graph = AudioHALOutput(channels: channels)
        try graph.configure(format: format, route: route,
                            hardware: { AudioHALDevice(id: 0, rate: outputRate, latencyMs: 0,
                                                      channelLayout: preferredLayout) }, connectHardware: false)
        #expect(graph.spatial == (channels > 2 && route.channels == 2))
        let input = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8_192))
        input.frameLength = 8_192
        let data = try #require(input.floatChannelData)
        for channel in 0..<channels { data[channel].update(repeating: 0, count: 8_192) }
        data[source][512] = 0.5
        #expect(Bool(graph.queue.pointee.write(data, frames: 8_192, isSilence: false)))
        graph.queue.pointee.enabled.store(true, ordering: .releasing)
        let outputTag = AudioHALDevice.layout(channels: graph.channels)
        let outputLayout = try #require(AVAudioChannelLayout(layoutTag: outputTag))
        let outputFormat = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: outputRate,
                                         interleaved: false, channelLayout: outputLayout)
        let output = try #require(AVAudioPCMBuffer(pcmFormat: outputFormat, frameCapacity: 512))
        let unit = try #require(graph.units.last)
        var energy = [Double](repeating: 0, count: Int(graph.channels))
        for quantum in 0..<16 {
            output.frameLength = 512
            var flags: AudioUnitRenderActionFlags = []
            var timestamp = AudioTimeStamp()
            timestamp.mFlags = .sampleTimeValid
            timestamp.mSampleTime = Double(quantum * 512)
            try #require(AudioUnitRender(unit, &flags, &timestamp, 0, 512, output.mutableAudioBufferList) == noErr)
            let rendered = try #require(output.floatChannelData)
            for channel in energy.indices {
                for frame in 0..<512 { energy[channel] += Double(rendered[channel][frame] * rendered[channel][frame]) }
            }
        }
        return energy
    }
}
