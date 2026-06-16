//
//  TelemetryCounters+InputActivity.swift
//
//  The input-activity accessors: the last-input stamp + idle→active edge
//  detection (`noteInputEvent`), the raw last-input instant for the
//  input-to-photon estimate, and the time-since-last-input read. Split out of
//  TelemetryCounters.swift to keep that file under the length limit (pure move,
//  same idiom as the FramePacer split). The stored state (the lock,
//  the stamp, `idleGapSeconds`) stays on the class in TelemetryCounters.swift -
//  stored properties cannot live in extensions.
//

import Foundation
import os

extension TelemetryCounters {

    // MARK: - Input activity (last-input stamp + idle-edge detection)

    /// Stamp an input event: update the last-input instant and flag an idle→active
    /// edge when the previous event was more than `idleGapSeconds` ago. Called from
    /// the InputBatcher producers (same sites as `inputEventsTotal.increment()`).
    func noteInputEvent() {
        let now = DispatchTime.now().uptimeNanoseconds
        os_unfair_lock_lock(inputLock)
        let prev = lastInputNanosValue
        lastInputNanosValue = now
        os_unfair_lock_unlock(inputLock)
        // Edge detection outside the lock: a stale `prev` read is harmless (the
        // worst case is mis-attributing one edge by a frame), and keeping the
        // counter increment off the inputLock avoids nesting two locks.
        if prev != 0 {
            let gapSeconds = Double(now &- prev) / 1_000_000_000.0
            if gapSeconds >= Self.idleGapSeconds {
                inputIdleToActiveTotal.increment()
            }
        }
    }

    /// Raw monotonic instant (`DispatchTime.now().uptimeNanoseconds`) of the most
    /// recent input event, or nil if none yet. Read on the present hot path by the
    /// input-to-photon estimate (signal 2): one short lock, only on the gate-on
    /// telemetry path (the tracker that reads it doesn't exist when off). This is
    /// the SAME stamp `noteInputEvent()` already writes from the InputBatcher
    /// producers - so input-to-photon adds NO new input-side write, only this
    /// present-side read.
    var lastInputNanos: UInt64? {
        os_unfair_lock_lock(inputLock)
        let last = lastInputNanosValue
        os_unfair_lock_unlock(inputLock)
        return last != 0 ? last : nil
    }

    /// Milliseconds since the last input event, or nil if no input yet. Read by
    /// the exporter on its 1Hz queue (never the hot path).
    func timeSinceLastInputMs() -> Double? {
        os_unfair_lock_lock(inputLock)
        let last = lastInputNanosValue
        os_unfair_lock_unlock(inputLock)
        guard last != 0 else { return nil }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= last else { return 0 }
        return Double(now &- last) / 1_000_000.0
    }
}

/// Last host-RUMBLE receipt instant - the input stamp's rumble sibling. Stamped
/// at protocol dispatch (EnetControlChannel.handleRumbleData, ~135/s during
/// active rumble - a sub-µs locked store) and read at the controller-detach
/// edge so the detach-context breadcrumb carries last-rumble age: the single
/// number that splits a mid-rumble radio drop (age ~seconds) from pad idle
/// auto-sleep (age ~minutes) - observed Bluetooth drops needed a manual
/// three-file join to recover it. Always-live like the counters; self-locked
/// (the `P2State` idiom) so the control path never touches another gauge's lock.
final class RumbleActivity: @unchecked Sendable {
    private let lock = os_unfair_lock_t.allocate(capacity: 1)
    private var lastRumbleNanos: UInt64 = 0
    init() { lock.initialize(to: os_unfair_lock_s()) }
    deinit { lock.deallocate() }

    /// Stamp a host-rumble receipt (called next to `rumbleEventTotal`).
    func stamp() {
        let now = DispatchTime.now().uptimeNanoseconds
        os_unfair_lock_lock(lock); lastRumbleNanos = now; os_unfair_lock_unlock(lock)
    }

    /// Clear the stamp at the connect edge (with `resetForNewSession`) so a
    /// prior session's rumble can never masquerade as this session's.
    func reset() {
        os_unfair_lock_lock(lock); lastRumbleNanos = 0; os_unfair_lock_unlock(lock)
    }

    /// Milliseconds since the last host-rumble receipt, or nil if none yet this
    /// session. Read at the (rare) detach edge - never a hot path.
    func ageMs() -> Double? {
        os_unfair_lock_lock(lock)
        let last = lastRumbleNanos
        os_unfair_lock_unlock(lock)
        guard last != 0 else { return nil }
        let now = DispatchTime.now().uptimeNanoseconds
        guard now >= last else { return 0 }
        return Double(now &- last) / 1_000_000.0
    }
}
