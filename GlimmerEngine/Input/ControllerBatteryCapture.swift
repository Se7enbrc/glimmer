// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

/// Battery level uses [0,1]; preserve the native negative/unknown sentinel instead of inventing a percentage.
public struct ControllerBatterySample: Sendable {
    public enum State: Sendable { case unknown, full, charging, discharging }
    public var state: State
    public var level: Float
    public init(state: State, level: Float) { self.state = state; self.level = level }
}

/// Battery reads are infrequent and run on the main actor, matching the native device API.
public struct ControllerBatteryCapture: Sendable {
    let read: @MainActor @Sendable () -> ControllerBatterySample?
    public init(read: @escaping @MainActor @Sendable () -> ControllerBatterySample?) { self.read = read }
    public var capabilities: ControllerDescriptor.Capabilities { .battery }
}
