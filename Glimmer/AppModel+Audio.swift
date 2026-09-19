//
//  AppModel+Audio.swift
//
//  "Mute the Mac while streaming" - captures the default output device and its
//  virtual main volume on stream start, drops it to zero, and restores that
//  same device on stop (or at the next launch, if the session died muted).
//  CoreAudio rather than an osascript shell-out.
//

import AudioToolbox
import CoreAudio
import Foundation

/// The output that was muted: its UID (stable across relaunches) and level.
struct MutedOutput: Codable, Equatable {
    let uid: String
    let volume: Float
}

extension AppModel {
    nonisolated static let mutePendingRestoreKey = "muteMacPendingRestore"

    // `prePausedMacOutput` non-nil is the did-mute LATCH: set exactly when we
    // drop the volume, cleared exactly when we put it back, so mute/restore
    // stay symmetric no matter what the live Settings flag does in between.
    func muteMac() {
        guard let device = Self.defaultOutputDeviceID() else { return }
        // Capture once: while a mute is latched the current level is our 0.
        if prePausedMacOutput == nil, let uid = Self.deviceUID(device) {
            let output = MutedOutput(uid: uid, volume: Self.volume(of: device))
            prePausedMacOutput = output
            Self.recordPendingRestore(output)
        }
        Self.setVolume(0, of: device)
    }

    /// No-op when nothing is latched, so callers may invoke unconditionally.
    func restoreMac() {
        if let output = prePausedMacOutput { Self.restore(output) }
        prePausedMacOutput = nil
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

    /// Launch-time recovery for a session that died while muted.
    static func restoreOrphanedMute() {
        guard let output = pendingRestore() else { return }
        restore(output)
        Diag.notice("Audio: restored the output muted by a session that ended early", "Launch")
    }

    /// Put the level back on the device that was muted, wherever the default
    /// output moved meanwhile. The record clears with the restore.
    private static func restore(_ output: MutedOutput) {
        if let device = deviceID(forUID: output.uid) { setVolume(output.volume, of: device) }
        UserDefaults.standard.removeObject(forKey: mutePendingRestoreKey)
    }

    nonisolated static func recordPendingRestore(_ output: MutedOutput, in defaults: UserDefaults = .standard) {
        defaults.set(try? JSONEncoder().encode(output), forKey: mutePendingRestoreKey)
    }

    nonisolated static func pendingRestore(in defaults: UserDefaults = .standard) -> MutedOutput? {
        guard let data = defaults.data(forKey: mutePendingRestoreKey) else { return nil }
        return try? JSONDecoder().decode(MutedOutput.self, from: data)
    }

    // MARK: CoreAudio

    private static func defaultOutputDeviceID() -> AudioObjectID? {
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

    private static func deviceUID(_ device: AudioObjectID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyDeviceUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var uid: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &uid) == noErr else { return nil }
        return uid?.takeRetainedValue() as String?
    }

    private static func deviceID(forUID uid: String) -> AudioObjectID? {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslateUIDToDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var cfUID = uid as CFString
        var device = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let st = withUnsafeMutablePointer(to: &cfUID) { qualifier in
            AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr,
                                       UInt32(MemoryLayout<CFString>.size), qualifier, &size, &device)
        }
        guard st == noErr, device != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return device
    }

    // The "virtual main volume" property models the single user-facing output
    // level even on devices whose hardware exposes only per-channel volume.
    private static func virtualMainVolumeAddress() -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume,
            mScope: kAudioObjectPropertyScopeOutput,
            mElement: kAudioObjectPropertyElementMain)
    }

    private static func volume(of device: AudioObjectID) -> Float {
        var addr = virtualMainVolumeAddress()
        guard AudioObjectHasProperty(device, &addr) else { return 0 }
        var volume = Float32(0)
        var size = UInt32(MemoryLayout<Float32>.size)
        guard AudioObjectGetPropertyData(device, &addr, 0, nil, &size, &volume) == noErr else { return 0 }
        return Float(volume)
    }

    private static func setVolume(_ volume: Float, of device: AudioObjectID) {
        var addr = virtualMainVolumeAddress()
        guard AudioObjectHasProperty(device, &addr) else { return }
        var settable: DarwinBoolean = false
        guard AudioObjectIsPropertySettable(device, &addr, &settable) == noErr, settable.boolValue else { return }
        var level = Float32(max(0, min(1, volume)))
        let size = UInt32(MemoryLayout<Float32>.size)
        _ = AudioObjectSetPropertyData(device, &addr, 0, nil, size, &level)
    }
}
