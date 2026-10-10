// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  MouseAccelerationControl.swift
//
//  Linear pointer scaling while a stream has focus, through the HID system's IOKit user client.
//

import Foundation
import IOKit
import IOKit.hidsystem

/// Turns the system's pointer-acceleration curve off while a stream is focused, so only the host game's own
/// sensitivity shapes aim. It is a global setting, so a UserDefaults sentinel lets the next launch put it back
/// if Glimmer dies mid-stream (`restoreOrphanedOverride`, called from GlimmerApp).
enum MouseAccelerationControl {
    /// Opt-in preference: aim without the pointer acceleration curve while a
    /// stream is focused. Registered in GlimmerApp; the Settings toggle mirrors it.
    static let enabledDefaultsKey = "disableMouseAccelWhileStreaming"
    /// Crash-safety sentinel: the user's linear-scaling flag WHILE ours is on.
    private static let pendingRestoreKey = "mouseLinearPendingRestore"
    /// Sentinel written by builds that overrode HIDMouseAcceleration itself.
    private static let legacyPendingRestoreKey = "mouseAccelPendingRestore"
    nonisolated(unsafe) private static var loggedAPIUnavailable = false

    static var isEnabled: Bool { UserDefaults.standard.bool(forKey: enabledDefaultsKey) }

    /// Turn linear scaling on (no velocity curve, Tracking Speed kept). Returns
    /// the user's prior flag to hand back on disengage, or nil when there is
    /// nothing of ours to undo: the API failed, or the user already runs linear.
    static func engageLinear() -> Bool? {
        guard let current = linearScaling() else {
            if !loggedAPIUnavailable {
                loggedAPIUnavailable = true
                Diag.notice("Mouse: linear-scaling parameter unavailable - raw aim disabled (stream unaffected)", "Input")
            }
            return nil
        }
        let defaults = UserDefaults.standard
        // An engagement is already live (a raced restore, a crashed session):
        // the sentinel holds the user's real flag, the read-back is ours.
        if defaults.object(forKey: pendingRestoreKey) != nil {
            let adopted = resolvePrior(readBack: current, sentinel: defaults.bool(forKey: pendingRestoreKey))
            defaults.set(adopted, forKey: pendingRestoreKey)
            setParameter(kIOHIDUseLinearScalingMouseAccelerationKey, NSNumber(value: true))
            return adopted
        }
        guard !current else { return nil }   // user already runs linear
        defaults.set(false, forKey: pendingRestoreKey)
        guard setParameter(kIOHIDUseLinearScalingMouseAccelerationKey, NSNumber(value: true)) else {
            defaults.removeObject(forKey: pendingRestoreKey)
            return nil
        }
        return false
    }

    /// The flag to restore when an engagement is already live: a read-back of
    /// "curve on" is a fresh truth (stale sentinel); "linear" is our own override.
    static func resolvePrior(readBack: Bool, sentinel: Bool) -> Bool {
        readBack ? sentinel : false
    }

    /// Restore the user's flag; the sentinel is cleared only once the write
    /// took, so a refused restore is retried at the next launch.
    static func restore(_ prior: Bool) {
        guard setParameter(kIOHIDUseLinearScalingMouseAccelerationKey, NSNumber(value: prior)) else { return }
        UserDefaults.standard.removeObject(forKey: pendingRestoreKey)
    }

    /// Launch-time crash recovery for a session that died while engaged. Also
    /// heals the pointer of a build that wrote HIDMouseAcceleration = -1.
    static func restoreOrphanedOverride() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: pendingRestoreKey) != nil {
            let prior = defaults.bool(forKey: pendingRestoreKey)
            if setParameter(kIOHIDUseLinearScalingMouseAccelerationKey, NSNumber(value: prior)) {
                defaults.removeObject(forKey: pendingRestoreKey)
                Diag.notice("Mouse: restored orphaned linear-scaling override to \(prior) "
                    + "(prior session ended while streaming)", "Launch")
            }
        }
        if defaults.object(forKey: legacyPendingRestoreKey) != nil {
            let saved = max(defaults.double(forKey: legacyPendingRestoreKey), 0)
            // The HID system keeps acceleration in 16.16 fixed point (1.5 reads back as 98304).
            setParameter(kIOHIDMouseAccelerationType, NSNumber(value: Int32(saved * 65_536)))
            defaults.removeObject(forKey: legacyPendingRestoreKey)
            Diag.notice("Mouse: restored orphaned pointer-acceleration override to \(saved) "
                + "(an earlier build ended while streaming)", "Launch")
        }
    }

    // MARK: - HID system parameters

    /// The linear-scaling flag from the HID system's registry entry; nil when it won't say.
    static func linearScaling() -> Bool? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        let parameters = IORegistryEntryCreateCFProperty(service, kIOHIDParametersKey as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any]
        return (parameters?[kIOHIDUseLinearScalingMouseAccelerationKey] as? NSNumber)?.boolValue
    }

    /// Writes one HID parameter through the system's parameter connection, the path the deprecated
    /// NXEventHandle calls took. True when the HID system accepted it.
    @discardableResult
    static func setParameter(_ key: String, _ value: NSNumber) -> Bool {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(kIOHIDSystemClass))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        var connect: io_connect_t = 0
        guard IOServiceOpen(service, mach_task_self_, UInt32(kIOHIDParamConnectType), &connect) == KERN_SUCCESS else {
            return false
        }
        defer { IOServiceClose(connect) }
        return IOConnectSetCFProperty(connect, key as CFString, value) == KERN_SUCCESS
    }
}
