// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import CoreAudio
import Foundation
import os

extension MacAudio {
    /// HAL output is explicitly bound to the default device when the graph is built.
    static var defaultOutputDeviceAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDefaultOutputDevice,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
    }

    /// Samples the default output as "<device name> [<transport>]", or "unknown".
    /// Blocks only during initialization or on the listener's utility queue.
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
