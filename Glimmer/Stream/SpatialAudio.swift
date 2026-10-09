import AVFoundation
import CoreAudio

struct AudioOutputRoute: Equatable, Sendable {
    enum Kind: Sendable {
        case headphones, builtInSpeakers, other
    }

    var channels = 2
    var kind: Kind = .other

    func spatialOutput(sourceChannels: Int) -> AVAudioEnvironmentOutputType? {
        guard sourceChannels > 2, channels == 2 else { return nil }
        switch kind {
        case .headphones: return .headphones
        case .builtInSpeakers: return .builtInSpeakers
        // The main mixer's stereo downmix omits LFE; Apple's speaker renderer retains it.
        case .other: return .externalSpeakers
        }
    }

    static func classify(transport: UInt32?, terminals: [UInt32]) -> Kind {
        if terminals.contains(kAudioStreamTerminalTypeHeadphones) { return .headphones }
        if transport == kAudioDeviceTransportTypeBuiltIn,
           terminals.contains(kAudioStreamTerminalTypeSpeaker) { return .builtInSpeakers }
        return .other
    }

    static func current() -> Self {
        guard let device = uintProperty(AudioObjectID(kAudioObjectSystemObject),
                                        selector: kAudioHardwarePropertyDefaultOutputDevice), device != 0 else {
            return Self()
        }
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                  mScope: kAudioDevicePropertyScopeOutput,
                                                  mElement: kAudioObjectPropertyElementMain)
        var bytes: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &bytes) == noErr,
              bytes > 0, bytes.isMultiple(of: UInt32(MemoryLayout<AudioStreamID>.size)) else { return Self() }
        var streams = [AudioStreamID](repeating: 0, count: Int(bytes) / MemoryLayout<AudioStreamID>.size)
        let status = streams.withUnsafeMutableBytes { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return kAudioHardwareUnspecifiedError }
            return AudioObjectGetPropertyData(device, &address, 0, nil, &bytes, base)
        }
        guard status == noErr else { return Self() }
        let channels = streams.reduce(0) { $0 + channelCount($1) }
        let terminals = streams.compactMap { uintProperty($0, selector: kAudioStreamPropertyTerminalType) }
        let transport = uintProperty(device, selector: kAudioDevicePropertyTransportType)
        return Self(channels: channels > 0 ? channels : 2, kind: classify(transport: transport, terminals: terminals))
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

    private static func uintProperty(_ object: AudioObjectID, selector: AudioObjectPropertySelector) -> UInt32? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: kAudioObjectPropertyScopeGlobal,
                                                  mElement: kAudioObjectPropertyElementMain)
        var value: UInt32 = 0
        var bytes = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(object, &address, 0, nil, &bytes, &value) == noErr else { return nil }
        return value
    }
}
