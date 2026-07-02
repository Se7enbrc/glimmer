//
//  AppModel+Audio.swift
//
//  "Mute the Mac while streaming" - captures the default output device's
//  virtual main volume on stream start, drops it to zero, and restores it on
//  stop. CoreAudio rather than an osascript shell-out. Split out of
//  AppModel.swift to keep the core type under the body-length limit.
//

import AudioToolbox
import CoreAudio
import Foundation

extension AppModel {
    // Capture the system output level on stream start, drop it to zero, and
    // restore it on stop. Backed by CoreAudio (see systemVolume/setSystemVolume).
    //
    // `prePausedMacVolume` non-nil is the did-mute LATCH: it is set exactly
    // when we drop the volume and cleared exactly when we put it back, so
    // mute/restore stay symmetric no matter what the live Settings flag does
    // in between.
    func muteMac() {
        // Capture once: if a previous mute is still latched (capture present,
        // restore not yet run), the CURRENT level is the 0 we set - not the
        // user's volume - and overwriting would destroy the only copy of it.
        if prePausedMacVolume == nil { prePausedMacVolume = systemVolume() }
        setSystemVolume(0)
    }

    /// No-op when nothing is latched, so callers may invoke unconditionally.
    func restoreMac() {
        if let volume = prePausedMacVolume { setSystemVolume(volume) }
        prePausedMacVolume = nil
    }

    /// Live-apply for the "Silence this Mac while streaming" toggle, called
    /// from its didSet. Settings is reachable mid-stream (⌘, on the
    /// backgrounded launcher) and the label is present-tense, so a flip acts
    /// NOW while a stream is live: ON → mute, OFF → restore. Outside a
    /// stream there is nothing to apply. The stream-end restore keys off the
    /// did-mute latch, NOT this flag, so a mid-stream flip can never strand
    /// the Mac at volume 0 the way the old flag-gated restore did.
    func applyMutePreferenceMidStream() {
        guard isStreaming else { return }
        if muteMacWhileStreaming {
            muteMac()
        } else {
            restoreMac()
        }
    }

    // System output volume via CoreAudio property access on the default output
    // device.
    private func defaultOutputDeviceID() -> AudioObjectID? {
        var deviceID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        let st = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
        guard st == noErr, deviceID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return deviceID
    }

    // The "virtual main volume" property models the single user-facing output
    // level even on devices whose hardware exposes only per-channel volume.
    private func virtualMainVolumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }

    private func systemVolume() -> Float {
        guard let dev = defaultOutputDeviceID() else { return 0 }
        var addr = virtualMainVolumeAddress()
        guard AudioObjectHasProperty(dev, &addr) else { return 0 }
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(dev, &addr, 0, nil, &size, &volume) == noErr else {
            return 0
        }
        return Float(volume)
    }

    private func setSystemVolume(_ volume: Float) {
        guard let dev = defaultOutputDeviceID() else { return }
        var addr = virtualMainVolumeAddress()
        guard AudioObjectHasProperty(dev, &addr) else { return }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(dev, &addr, &settable) == noErr,
              settable.boolValue else { return }
        var level = Float32(max(0, min(1, volume)))
        let size = UInt32(MemoryLayout<Float32>.size)
        _ = AudioObjectSetPropertyData(dev, &addr, 0, nil, size, &level)
    }
}
