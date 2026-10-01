//
//  AudioDecoder+Route.swift
//
//  The audio OUTPUT route sampler: the default-output-device listener that keeps
//  a cached "<device> [<transport>]" string, and the blocking HAL probe behind
//  it. That cached string is the under-run attribution breadcrumb - the meter's
//  NOTICE carries it from the player's completion thread, which may make no
//  CoreAudio/AV call of its own. Split from AudioDecoder+Meter.swift - same
//  idiom as the FramePacer split, to keep that file under the length limit. The
//  listener handle + the cached route live on the class (stored properties can't
//  live in extensions); see the property docs in AudioDecoder.swift for the
//  locking rationale.
//

import CoreAudio
import Foundation
import os

extension AudioDecoder {

    // MARK: - Audio OUTPUT route (under-run attribution breadcrumbs)

    /// One sample of the default output route: the breadcrumb label and the
    /// device UID the resampler's skew memory is keyed by (local only, never logged).
    struct AudioRoute {
        let label: String
        let uid: String?
    }

    /// Hex identity of this instance for the lifecycle lines, so a decoder
    /// that outlives its session is traceable in the log.
    var logID: String { String(UInt(bitPattern: ObjectIdentifier(self)), radix: 16) }

    /// Install the default-output-device listener + seed the route cache. Called
    /// once from `initDecoderCore` with `stateLock` held (after the engine is up);
    /// idempotent via the token. WHY a listener instead of sampling at the
    /// under-run: route reads are blocking HAL IPC - putting one on the completion
    /// thread (or the 200Hz decode path) would risk the very stalls the cushion
    /// absorbs. The listener pays that cost on its own utility queue, only when
    /// the device actually changes, and the hot paths read a cached String. The
    /// route-CHANGE NOTICE it emits is itself the attribution breadcrumb the
    /// under-run cascades were missing (a BT detach lands here seconds before the
    /// drains it triggers).
    func installAudioRouteListener(initial route: AudioRoute) {
        guard routeListenerKey == nil else { return }
        audioMeterLock.lock()
        audioRouteCache = route.label
        audioMeterLock.unlock()
        // First-sample NOTICE - a new sampler announces itself (success AND
        // failure shape) rather than going silently dark.
        Diag.notice("audio output route: \(route.label, privacy: .private)", "Stream")
        let queue = routeListenerQueue
        let system = AudioObjectID(kAudioObjectSystemObject)
        let (key, status) = HALListener.add(system, Self.defaultOutputDeviceAddress) { [weak self] in
            guard let decoder = self else { return }
            queue.async { decoder.noteRouteChange() }
        }
        if status == noErr {
            routeListenerKey = key
            Diag.notice("audio route listener installed (decoder \(logID))", "Stream")
        } else {
            Diag.notice(
                "audio route listener install failed (OSStatus \(status)) - "
                + "under-run route attribution will not track device switches",
                "Stream")
        }
    }

    /// A default-output change, on the route queue: resample the route and note a real move.
    private func noteRouteChange() {
        let fresh = Self.sampleAudioRoute()
        audioMeterLock.lock()
        let previous = audioRouteCache
        audioRouteCache = fresh.label
        noteOutputDeviceLocked(uid: fresh.uid)
        audioMeterLock.unlock()
        if fresh.label != previous {
            Diag.notice("audio route changed: \(previous, privacy: .private) → \(fresh.label, privacy: .private)", "Stream")
        }
    }

    /// Remove the route listener. Called from `shutdown()` with `stateLock` held; safe when the install failed
    /// or never ran.
    func removeAudioRouteListener() {
        guard let key = routeListenerKey else { return }
        routeListenerKey = nil
        let status = HALListener.remove(AudioObjectID(kAudioObjectSystemObject), Self.defaultOutputDeviceAddress, key: key)
        Diag.notice("audio route listener removed (decoder \(logID), OSStatus \(status))", "Stream")
    }

    /// The HAL address of the system default OUTPUT device - AVAudioEngine's
    /// outputNode tracks this device, so it IS the playback route.
    private static var defaultOutputDeviceAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    /// One blocking sample of the current default-output route, labeled
    /// "<device name> [<transport>]" (e.g. "MacBook Pro Speakers [builtin]").
    /// Same probe idiom as `AudioConfig.currentDefaultOutputChannelCount`.
    /// Returns "unknown" if the HAL won't answer - never throws. Call sites: init
    /// + the listener's utility queue only, never a hot path.
    static func sampleAudioRoute() -> AudioRoute {
        var deviceID = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        var addr = defaultOutputDeviceAddress
        guard AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID) == noErr,
            deviceID != 0 else { return AudioRoute(label: "unknown", uid: nil) }

        let name = stringProperty(kAudioObjectPropertyName, of: deviceID) ?? "unnamed"
        var transportAddr = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyTransportType,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var transportSize = UInt32(MemoryLayout<UInt32>.size)
        let transportStatus = AudioObjectGetPropertyData(
            deviceID, &transportAddr, 0, nil, &transportSize, &transport)
        let label = transportStatus == noErr ? Self.transportLabel(transport) : "?"
        return AudioRoute(label: "\(name) [\(label)]",
                          uid: stringProperty(kAudioDevicePropertyDeviceUID, of: deviceID))
    }

    /// A CFString device property (name, UID), or nil if the HAL won't answer.
    private static func stringProperty(_ selector: AudioObjectPropertySelector,
                                       of deviceID: AudioDeviceID) -> String? {
        var addr = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var ref: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        let status = withUnsafeMutablePointer(to: &ref) {
            AudioObjectGetPropertyData(deviceID, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let value = ref?.takeRetainedValue() else { return nil }
        return value as String
    }

    /// Short label for the HAL transport type - BT vs built-in vs USB is the
    /// load-bearing distinction for drain attribution.
    private static func transportLabel(_ transport: UInt32) -> String {
        switch transport {
        case kAudioDeviceTransportTypeBuiltIn: return "builtin"
        case kAudioDeviceTransportTypeBluetooth,
             kAudioDeviceTransportTypeBluetoothLE: return "bluetooth"
        case kAudioDeviceTransportTypeUSB: return "usb"
        case kAudioDeviceTransportTypeHDMI: return "hdmi"
        case kAudioDeviceTransportTypeDisplayPort: return "displayport"
        case kAudioDeviceTransportTypeThunderbolt: return "thunderbolt"
        case kAudioDeviceTransportTypeAirPlay: return "airplay"
        case kAudioDeviceTransportTypeAggregate: return "aggregate"
        case kAudioDeviceTransportTypeVirtual: return "virtual"
        default: return String(format: "0x%08x", transport)
        }
    }
}

/// HAL property listeners on the function-pointer API, which the HAL matches on function and context: Swift
/// hands a C API a fresh block on every call, so a block-based remove never matched. The context is a key,
/// never a pointer, so a callback racing its removal finds no handler instead of freed memory.
enum HALListener {
    private static let handlers = OSAllocatedUnfairLock(initialState: (next: 1, table: [Int: @Sendable () -> Void]()))

    /// Calls `handler` on the HAL's thread whenever `address` on `object` changes; `key` is what `remove` needs.
    static func add(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress,
                    handler: @escaping @Sendable () -> Void) -> (key: Int, status: OSStatus) {
        let key = handlers.withLock { state -> Int in
            let key = state.next
            state.next += 1
            state.table[key] = handler
            return key
        }
        var address = address
        let status = AudioObjectAddPropertyListener(object, &address, halListenerFired, UnsafeMutableRawPointer(bitPattern: key))
        if status != noErr { handlers.withLock { _ = $0.table.removeValue(forKey: key) } }
        return (key, status)
    }

    @discardableResult
    static func remove(_ object: AudioObjectID, _ address: AudioObjectPropertyAddress, key: Int) -> OSStatus {
        handlers.withLock { _ = $0.table.removeValue(forKey: key) }
        var address = address
        return AudioObjectRemovePropertyListener(object, &address, halListenerFired, UnsafeMutableRawPointer(bitPattern: key))
    }

    fileprivate static func fire(_ key: Int) {
        handlers.withLock { $0.table[key] }?()
    }
}

/// The one function every HALListener registers, so add and remove always name the same pointer.
private func halListenerFired(_: AudioObjectID, _: UInt32, _: UnsafePointer<AudioObjectPropertyAddress>,
                              _ context: UnsafeMutableRawPointer?) -> OSStatus {
    HALListener.fire(Int(bitPattern: context))
    return noErr
}
