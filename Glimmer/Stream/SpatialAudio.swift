// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AudioToolbox
import GlimmerEngine
import CoreAudio
import IOKit.audio

struct AudioOutputRoute: Equatable, Sendable {
    enum Kind: Sendable {
        case headphones, builtInSpeakers, other
    }

    var channels = 2
    var kind: Kind = .other
    var device: AudioDeviceID = 0
    var transport: UInt32?
    var terminals: [UInt32] = []
    var dataSource: UInt32?

    func logRoute() {
        let transport = transport.map { String($0, radix: 16) } ?? "unknown"
        let terminals = terminals.map { String($0, radix: 16) }.joined(separator: ",")
        let source = dataSource.map { String($0, radix: 16) } ?? "unknown"
        Diag.info("Audio route: transport=0x\(transport) terminals=[\(terminals)] "
            + "dataSource=0x\(source) channels=\(channels) kind=\(String(describing: kind))", "Stream.Audio")
    }

    func spatialOutput(sourceChannels: Int) -> AUSpatialMixerOutputType? {
        guard sourceChannels > 2, channels == 2 else { return nil }
        switch kind {
        case .headphones: return AUSpatialMixerOutputType.spatialMixerOutputType_Headphones
        // The built-in renderer drops LFE; an explicit stereo downmix keeps every source channel.
        case .builtInSpeakers: return nil
        // The main mixer's stereo downmix omits LFE; Apple's speaker renderer retains it.
        case .other: return AUSpatialMixerOutputType.spatialMixerOutputType_ExternalSpeakers
        }
    }

    static func classify(transport: UInt32?, terminals: [UInt32], dataSource: UInt32? = nil) -> Kind {
        // Apple Silicon HAL streams can expose IOAudio's numeric terminal types instead of FourCCs.
        if terminals.contains(kAudioStreamTerminalTypeHeadphones) || terminals.contains(UInt32(OUTPUT_HEADPHONES)) {
            return .headphones
        }
        guard transport == kAudioDeviceTransportTypeBuiltIn else { return .other }
        if dataSource == UInt32(kIOAudioSelectorControlSelectionValueHeadphones) { return .headphones }
        if terminals.contains(kAudioStreamTerminalTypeSpeaker) || terminals.contains(UInt32(OUTPUT_SPEAKER))
            || dataSource == UInt32(kIOAudioSelectorControlSelectionValueInternalSpeaker) {
            return .builtInSpeakers
        }
        return .other
    }

    /// The default output's route, or nil when the HAL can't answer (a device mid-transition).
    static func current() -> Self? {
        guard let device = uintProperty(AudioObjectID(kAudioObjectSystemObject),
                                        selector: kAudioHardwarePropertyDefaultOutputDevice), device != 0 else {
            return nil
        }
        guard let streams = outputStreams(device: device) else { return nil }
        let channels = streams.reduce(0) { $0 + channelCount($1) }
        let terminals = streams.compactMap { uintProperty($0, selector: kAudioStreamPropertyTerminalType) }
        let transport = uintProperty(device, selector: kAudioDevicePropertyTransportType)
        let source = uintProperty(device, selector: kAudioDevicePropertyDataSource,
                                  scope: kAudioDevicePropertyScopeOutput)
        return Self(channels: channels > 0 ? channels : 2,
                    kind: classify(transport: transport, terminals: terminals, dataSource: source),
                    device: device, transport: transport, terminals: terminals, dataSource: source)
    }

    static func outputStreams(device: AudioDeviceID) -> [AudioStreamID]? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                  mScope: kAudioDevicePropertyScopeOutput,
                                                  mElement: kAudioObjectPropertyElementMain)
        var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &bytes) == noErr,
              bytes > 0, bytes.isMultiple(of: UInt32(MemoryLayout<AudioStreamID>.size)) else { return nil }
        var streams = [AudioStreamID](repeating: 0, count: Int(bytes) / MemoryLayout<AudioStreamID>.size)
        let status = streams.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return kAudioHardwareUnspecifiedError }
            return AudioObjectGetPropertyData(device, &address, 0, nil, &bytes, base)
        }
        return status == noErr ? streams : nil
    }

    private static func channelCount(_ stream: AudioStreamID) -> Int {
        var address = AudioObjectPropertyAddress(mSelector: kAudioStreamPropertyVirtualFormat,
                                                  mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var format = AudioStreamBasicDescription()
        var bytes = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        guard AudioObjectGetPropertyData(stream, &address, 0, nil, &bytes, &format) == noErr else { return 0 }
        return Int(format.mChannelsPerFrame)
    }

    private static func uintProperty(
        _ object: AudioObjectID, selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                  mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var bytes = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &bytes, &value) == noErr else { return nil }
        return value
    }
}
