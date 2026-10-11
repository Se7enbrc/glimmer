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
        let latency: UInt32 = try read(device, selector: kAudioDevicePropertyLatency,
                                       scope: kAudioDevicePropertyScopeOutput, initial: UInt32(0))
        let safety: UInt32 = try read(device, selector: kAudioDevicePropertySafetyOffset,
                                      scope: kAudioDevicePropertyScopeOutput, initial: UInt32(0))
        let buffer: UInt32 = try read(device, selector: kAudioDevicePropertyBufferFrameSize, initial: UInt32(0))
        return Self(id: device, rate: rate,
                    latencyMs: (Double(latency) + Double(safety) + Double(buffer)) / rate * 1000,
                    channelLayout: preferredLayout(device))
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
            (kAudioDevicePropertyBufferFrameSize, kAudioObjectPropertyScopeGlobal)
        ]
        for (selector, scope) in properties {
            observeAudioProperty(device, address: AudioHALDevice.address(selector, scope: scope))
        }
        for stream in AudioOutputRoute.outputStreams(device: device) ?? [] {
            for selector in [kAudioStreamPropertyVirtualFormat, kAudioStreamPropertyPhysicalFormat] {
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
