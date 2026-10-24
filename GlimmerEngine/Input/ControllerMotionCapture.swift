// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

/// Raw GC sensor units: gravity-inclusive acceleration in G, rotation in radians/second.
public struct ControllerMotionSample: Sendable {
    public var acceleration: SIMD3<Float>
    public var rotation: SIMD3<Float>
    public init(acceleration: SIMD3<Float>, rotation: SIMD3<Float>) {
        self.acceleration = acceleration
        self.rotation = rotation
    }
}

/// Prepared sensor access. Native callbacks submit snapshots synchronously on the capture thread.
/// Installation/power hooks must tolerate serialized calls from lifecycle and capture threads.
public struct ControllerMotionCapture: Sendable {
    let hasAcceleration: Bool
    let hasRotation: Bool
    let read: @Sendable () -> ControllerMotionSample?
    let setHandler: @Sendable ((@Sendable (ControllerMotionSample) -> Void)?) -> Void
    let setSensorsActive: @Sendable (Bool) -> Void

    public init(hasAcceleration: Bool, hasRotation: Bool,
                read: @escaping @Sendable () -> ControllerMotionSample?,
                setHandler: @escaping @Sendable ((@Sendable (ControllerMotionSample) -> Void)?) -> Void,
                setSensorsActive: @escaping @Sendable (Bool) -> Void) {
        self.hasAcceleration = hasAcceleration
        self.hasRotation = hasRotation
        self.read = read
        self.setHandler = setHandler
        self.setSensorsActive = setSensorsActive
    }

    public var capabilities: ControllerDescriptor.Capabilities {
        var value: ControllerDescriptor.Capabilities = []
        if hasAcceleration { value.insert(.accelerometer) }
        if hasRotation { value.insert(.gyroscope) }
        return value
    }
}
