// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AVFAudio
import AudioToolbox
import CoreAudio
import Foundation

struct AudioHALDevice {
    let id: AudioDeviceID
    let rate: Double
    let latencyMs: Double
    var channelLayout: AVAudioChannelLayout?

    static func current() throws -> Self {
        let device: UInt32 = try read(AudioObjectID(kAudioObjectSystemObject),
                                     selector: kAudioHardwarePropertyDefaultOutputDevice, initial: UInt32(0))
        guard device != 0 else { throw AudioHALOutput.Failure(status: kAudioHardwareBadDeviceError) }
        let alive: UInt32 = try read(device, selector: kAudioDevicePropertyDeviceIsAlive, initial: UInt32(0))
        let rate: Double = try read(device, selector: kAudioDevicePropertyNominalSampleRate, initial: 0.0)
        guard alive != 0, rate.isFinite, rate > 0 else {
            throw AudioHALOutput.Failure(status: kAudioHardwareBadDeviceError)
        }
        return Self(id: device, rate: rate, latencyMs: try outputLatencyMs(device: device, rate: rate),
                    channelLayout: preferredLayout(device))
    }

    static func stereoChannelMap(channels: Int, preferred: (UInt32, UInt32)) throws -> [Int32] {
        guard preferred.0 > 0, preferred.1 > 0, preferred.0 != preferred.1,
              preferred.0 <= channels, preferred.1 <= channels else {
            throw AudioHALOutput.Failure(status: kAudioUnitErr_FormatNotSupported)
        }
        var map = [Int32](repeating: -1, count: channels)
        map[Int(preferred.0) - 1] = 0
        map[Int(preferred.1) - 1] = 1
        return map
    }

    static func outputLatencyMs(device: AudioDeviceID, rate: Double,
                                streams: (AudioDeviceID) -> [AudioStreamID]? = AudioOutputRoute.outputStreams,
                                readUInt: (AudioObjectID, AudioObjectPropertySelector,
                                           AudioObjectPropertyScope) throws -> UInt32 = {
                                    try read($0, selector: $1, scope: $2, initial: UInt32(0))
                                }) throws -> Double {
        let latency = try readUInt(device, kAudioDevicePropertyLatency, kAudioDevicePropertyScopeOutput)
        let safety = try readUInt(device, kAudioDevicePropertySafetyOffset, kAudioDevicePropertyScopeOutput)
        let buffer = try readUInt(device, kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal)
        guard let streams = streams(device) else {
            throw AudioHALOutput.Failure(status: kAudioHardwareBadStreamError)
        }
        // Streams run in parallel; the slowest active path bounds the reported device output latency.
        var streamLatency: UInt32 = 0
        for stream in streams {
            guard try readUInt(stream, kAudioStreamPropertyIsActive, kAudioObjectPropertyScopeGlobal) != 0 else {
                continue
            }
            streamLatency = max(streamLatency,
                try readUInt(stream, kAudioStreamPropertyLatency, kAudioObjectPropertyScopeGlobal))
        }
        return (Double(latency) + Double(safety) + Double(buffer) + Double(streamLatency)) / rate * 1000
    }

    private static func preferredLayout(_ device: AudioDeviceID) -> AVAudioChannelLayout? {
        var address = address(kAudioDevicePropertyPreferredChannelLayout, scope: kAudioDevicePropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr,
              size >= 3 * MemoryLayout<UInt32>.size else { return nil }
        let storage = UnsafeMutableRawPointer.allocate(byteCount: Int(size),
                                                      alignment: MemoryLayout<AudioChannelLayout>.alignment)
        defer { storage.deallocate() }
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, storage) == noErr else { return nil }
        let layout = storage.assumingMemoryBound(to: AudioChannelLayout.self)
        let needed = 3 * MemoryLayout<UInt32>.size
            + Int(layout.pointee.mNumberChannelDescriptions) * MemoryLayout<AudioChannelDescription>.size
        guard needed <= Int(size) else { return nil }
        return AVAudioChannelLayout(layout: layout)
    }

    static func read<T>(_ object: AudioObjectID, selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal, initial: T) throws -> T {
        var address = address(selector, scope: scope)
        var value = initial
        var size = UInt32(MemoryLayout<T>.size)
        let status = withUnsafeMutablePointer(to: &value) {
            AudioObjectGetPropertyData(object, &address, 0, nil, &size, $0)
        }
        guard status == noErr else { throw AudioHALOutput.Failure(status: status) }
        return value
    }

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func outputChannels(source: Int, route: AudioOutputRoute) -> Int {
        if route.spatialOutput(sourceChannels: source) != nil { return 2 }
        return [2, 6, 8].contains(route.channels) ? route.channels : min(2, max(1, route.channels))
    }

    static func layout(channels: UInt32) -> AudioChannelLayoutTag {
        switch channels {
        case 1: return kAudioChannelLayoutTag_Mono
        case 6: return kAudioChannelLayoutTag_AudioUnit_5_1
        case 8: return kAudioChannelLayoutTag_AudioUnit_7_1
        default: return kAudioChannelLayoutTag_Stereo
        }
    }
}

extension AudioDecoder {
    func installDeviceListeners() {
        removeDeviceListeners()
        let fallback = try? AudioHALDevice.read(AudioObjectID(kAudioObjectSystemObject),
                                                selector: kAudioHardwarePropertyDefaultOutputDevice, initial: UInt32(0))
        guard let device = halOutput?.device ?? fallback, device != 0 else { return }
        let properties: [(AudioObjectPropertySelector, AudioObjectPropertyScope)] = [
            (kAudioDevicePropertyNominalSampleRate, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyDeviceIsAlive, kAudioObjectPropertyScopeGlobal),
            (kAudioDevicePropertyStreamConfiguration, kAudioDevicePropertyScopeOutput),
            (kAudioDevicePropertyPreferredChannelLayout, kAudioDevicePropertyScopeOutput),
            (kAudioDevicePropertyPreferredChannelsForStereo, kAudioDevicePropertyScopeOutput),
            (kAudioDevicePropertyLatency, kAudioDevicePropertyScopeOutput),
            (kAudioDevicePropertySafetyOffset, kAudioDevicePropertyScopeOutput),
            (kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal)
        ]
        for (selector, scope) in properties {
            observeAudioProperty(device, address: AudioHALDevice.address(selector, scope: scope))
        }
        for stream in AudioOutputRoute.outputStreams(device: device) ?? [] {
            for selector in [kAudioStreamPropertyVirtualFormat, kAudioStreamPropertyPhysicalFormat,
                             kAudioStreamPropertyLatency, kAudioStreamPropertyIsActive] {
                observeAudioProperty(stream, address: AudioHALDevice.address(selector))
            }
        }
    }

    private func observeAudioProperty(_ object: AudioObjectID, address: AudioObjectPropertyAddress) {
        let result = HALListener.add(object, address) { [weak self] in
            guard let self else { return }
            let changedAt = DispatchTime.now().uptimeNanoseconds
            self.routeListenerQueue.async { self.handleEngineConfigurationChange(changedAt: changedAt) }
        }
        if result.status == noErr {
            deviceListeners.append((object, address, result.key))
        } else {
            Diag.error("audio device listener failed (OSStatus \(result.status))", "Stream.Audio")
        }
    }

    func removeDeviceListeners() {
        for (device, address, key) in deviceListeners {
            let status = HALListener.remove(device, address, key: key)
            if status != noErr {
                Diag.error("audio device listener remove failed (OSStatus \(status))", "Stream.Audio")
            }
        }
        deviceListeners.removeAll()
    }
}
