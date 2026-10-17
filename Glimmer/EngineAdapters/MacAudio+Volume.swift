// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import AudioToolbox
import CoreAudio

enum MacAudioVolume {
    static func readDefaultOutputVolume(initialDevice: AudioObjectID?) -> AudioOutputVolume {
        var halVolume: Float?
        var halMuted: Bool?
        let before = Self.defaultOutputDevice()
        if let device = before {
            halVolume = Self.read(device, selector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
                                  scope: kAudioObjectPropertyScopeOutput, initial: Float32(0))
                ?? Self.read(device, selector: kAudioDevicePropertyVolumeScalar,
                             scope: kAudioObjectPropertyScopeOutput, initial: Float32(0))
            let mute: UInt32? = Self.read(device, selector: kAudioDevicePropertyMute,
                                         scope: kAudioObjectPropertyScopeOutput, initial: UInt32(0))
            halMuted = mute.map { $0 != 0 }
        }
        return AudioOutputVolume(volume: halVolume, muted: halMuted,
                                 routeChanged: initialDevice != before || before != Self.defaultOutputDevice())
    }

    static func defaultOutputDevice() -> AudioObjectID? {
        let device: UInt32? = read(AudioObjectID(kAudioObjectSystemObject),
                                  selector: kAudioHardwarePropertyDefaultOutputDevice,
                                  scope: kAudioObjectPropertyScopeGlobal, initial: UInt32(0))
        return device == kAudioObjectUnknown ? nil : device
    }

    private static func read<Value>(_ object: AudioObjectID, selector: AudioObjectPropertySelector,
                                    scope: AudioObjectPropertyScope, initial: Value) -> Value? {
        var address = AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                                mElement: kAudioObjectPropertyElementMain)
        guard AudioObjectHasProperty(object, &address) else { return nil }
        var value = initial
        var size = UInt32(MemoryLayout<Value>.size)
        let status = withUnsafeMutableBytes(of: &value) { buffer -> OSStatus in
            guard let base = buffer.baseAddress else { return kAudioHardwareUnspecifiedError }
            return AudioObjectGetPropertyData(object, &address, 0, nil, &size, base)
        }
        return status == noErr ? value : nil
    }
}
