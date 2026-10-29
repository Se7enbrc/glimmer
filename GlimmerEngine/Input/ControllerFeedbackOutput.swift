// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

/// Native motor lifetime. The engine serializes updates on its feedback queue; stop is idempotent.
public final class ControllerMotor: @unchecked Sendable {
    let id = UUID()
    private let lock = NSRecursiveLock()
    private var stopped = false
    private let update: @Sendable (Float) throws -> Void
    private let dispose: @Sendable () -> Void

    public init(updateIntensity: @escaping @Sendable (Float) throws -> Void,
                stop: @escaping @Sendable () -> Void) {
        update = updateIntensity
        dispose = stop
    }

    func setIntensity(_ value: Float) throws {
        try lock.withLock { if !stopped { try update(value) } }
    }

    func stop() {
        lock.withLock {
            guard !stopped else { return }
            stopped = true
            dispose()
        }
    }

    deinit { stop() }
}

/// Prepared native actuation functions, called on the engine's serial feedback queue.
/// Factory callbacks may arrive on any thread; they invalidate only the motor that supplied them.
public struct ControllerFeedbackOutput: Sendable {
    public enum Locality: String, Sendable, Hashable {
        case leftHandle, rightHandle, leftTrigger, rightTrigger, handles, all
    }
    public typealias MotorFactory = @Sendable (Locality, Float, Float,
        @escaping @Sendable (String) -> Void) throws -> ControllerMotor?

    let localities: Set<Locality>
    let makeMotor: MotorFactory
    let setLight: (@Sendable (UInt8, UInt8, UInt8) -> Void)?
    let setPlayerIndex: (@Sendable (Int) -> Bool)?
    package var mirrorRumble: (@Sendable (UInt16, UInt16) -> Void)?
    package var mirrorLight: (@Sendable (UInt8, UInt8, UInt8) -> Void)?

    /// Factory arguments are locality, spectral sharpness, initial intensity and invalidation callback.
    /// Start at the supplied intensity; report stop/reset through the callback, and release native objects on stop.
    public init(localities: Set<Locality>, makeMotor: @escaping MotorFactory,
                setLight: (@Sendable (UInt8, UInt8, UInt8) -> Void)? = nil,
                setPlayerIndex: (@Sendable (Int) -> Bool)? = nil) {
        self.localities = localities
        self.makeMotor = makeMotor
        self.setLight = setLight
        self.setPlayerIndex = setPlayerIndex
    }

    public var capabilities: ControllerDescriptor.Capabilities {
        var value: ControllerDescriptor.Capabilities = []
        if !localities.isEmpty { value.insert(.rumble) }
        if localities.contains(.leftTrigger), localities.contains(.rightTrigger) { value.insert(.triggerRumble) }
        if setLight != nil { value.insert(.rgbLED) }
        return value
    }
}
