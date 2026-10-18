// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

/// The recursive lock owns registration, sensor gates and the uplink across lifecycle and GC handler threads.
package final class ControllerMotion: @unchecked Sendable {
    private let lock = NSRecursiveLock()
    package static let logCategory = "Controller"

    /// Cap host-requested sensor rates at the existing 200 Hz ceiling, bounding each two-sensor pad to
    /// 400 reliable reports per second.
    private static let maxReportRateHz: UInt16 = 200

    /// G → m/s^2 (SDL_STANDARD_GRAVITY; the moonlight-ios constant).
    private static let gravity: Float = 9.80665
    /// rad/s → deg/s (the moonlight-ios constant).
    private static let degPerRad: Float = 57.2957795

    /// LI_MOTION_TYPE_* narrowed once to the wire's u8.
    private static let accelType = UInt8(StreamProtocol.LI_MOTION_TYPE_ACCEL)
    private static let gyroType = UInt8(StreamProtocol.LI_MOTION_TYPE_GYRO)

    // MARK: - Locked sampler state

    /// slot (the forwarder's 0..15 controllerNumber) → sampling state.
    private var pads: [UInt8: Pad] = [:]
    // Activation holds the backend latch, so it must not wait for a sampler making a backend call.
    private let uplinkLock = NSLock()
    private weak var activeUplink: (any StreamingBackend)?
    private var uplink: (any StreamingBackend)? {
        get { uplinkLock.withLock { activeUplink } }
        set { uplinkLock.withLock { activeUplink = newValue } }
    }

    package init() {}

    // MARK: - Registration (ControllerForwarder, main thread)

    /// Register prepared capture capabilities and the slot mapping; native probing remains with the
    /// adapter.
    package func register(slot: UInt8, capture: ControllerMotionCapture, inputEnabled: Bool) -> UInt16 {
        lock.lock(); defer { lock.unlock() }
        // A re-attach can reuse a slot before detach bookkeeping settles;
        // halt the stale pad's sampling so the swap can't strand a live handler.
        if let stale = pads.removeValue(forKey: slot) {
            halt(pad: stale, slot: slot, why: "slot reassigned")
        }
        var caps: UInt16 = 0
        if capture.hasAcceleration {
            caps |= UInt16(StreamProtocol.LI_CCAP_ACCEL)
        }
        if capture.hasRotation {
            caps |= UInt16(StreamProtocol.LI_CCAP_GYRO)
        }
        guard caps != 0 else { return 0 }
        pads[slot] = Pad(capture: capture, inputEnabled: inputEnabled)
        return caps
    }

    /// Retain the PC's sensor requests while ownership is away, then resume from current motion.
    package func setInputEnabled(_ enabled: Bool, slot: UInt8) {
        lock.lock(); defer { lock.unlock() }
        guard let pad = pads[slot], pad.inputEnabled != enabled else { return }
        pad.inputEnabled = enabled
        if !enabled, pad.rates[Int(Self.gyroType) - 1] != 0 { sendGyroNull(slot: slot) }
        for idx in pad.rates.indices {
            pad.lastSample[idx] = nil
            pad.gates[idx] = MotionRateGate()
        }
        refreshSampling(pad, slot: slot)
        if enabled, let sample = pad.capture.read() { receive(slot: slot, token: pad.token,
            generation: pad.generation, sample: sample) }
    }

    /// Drop a slot's mapping and halt its sampling (controller detach).
    package func unregister(slot: UInt8) {
        lock.lock(); defer { lock.unlock() }
        guard let pad = pads.removeValue(forKey: slot) else { return }
        halt(pad: pad, slot: slot, why: "controller detached")
    }

    // MARK: - Stream lifecycle (NativeBackend+Pipeline)

    /// Arm the uplink for a new stream session. Wired in startVideoStage
    /// alongside enet.onSetMotionEvent, so samples become possible exactly
    /// when host enables can start arriving.
    package func streamActivated(backend: any StreamingBackend) {
        uplink = backend
    }

    /// Stop all sensor capture and clear the uplink when the stream ends; late callbacks fail the
    /// registration/generation guards.
    package func stopAll(reason: String) {
        lock.lock(); defer { lock.unlock() }
        for (slot, pad) in pads { halt(pad: pad, slot: slot, why: reason) }
        uplink = nil
    }

    // MARK: - Host enable intake (enet receive thread)

    /// Apply a rare host sensor-enable/rate change synchronously under the motion lock. Native handler
    /// and power hooks receive the resulting policy.
    package func setMotionEventState(controllerNumber: UInt16, motionType: UInt8, reportRateHz: UInt16) {
        // The host echoes the controllerNumber WE assigned (the forwarder's
        // 0..15 slot); anything else can't be ours. Unknown motion types
        // have no sensor behind them (LI_MOTION_TYPE_* is 1-based, two types).
        guard controllerNumber < UInt16(Enet.maxGamepads),
              motionType == Self.accelType || motionType == Self.gyroType else { return }
        let slot = UInt8(controllerNumber)
        apply(slot: slot, motionType: motionType, reportRateHz: reportRateHz)
    }

    // MARK: - Sampling state machine

    /// Start/retune/stop one sensor's reporting per the host's request.
    package func apply(slot: UInt8, motionType: UInt8, reportRateHz: UInt16) {
        lock.lock(); defer { lock.unlock() }
        guard let pad = pads[slot] else { return }
        let idx = Int(motionType) - 1
        let rate = min(reportRateHz, Self.maxReportRateHz)
        // The host may re-announce an unchanged state; only act on change
        // (the handleHdrInfo transition-gating discipline).
        guard pad.rates[idx] != rate else { return }
        let wasActive = pad.rates[idx] != 0
        pad.rates[idx] = rate
        pad.lastSample[idx] = nil
        pad.gates[idx] = MotionRateGate()

        if rate == 0 {
            // Host-requested stop. Null an active gyro (see halt()'s WHY) and
            // power the IMU down if both sensors are now idle.
            if motionType == Self.gyroType { sendGyroNull(slot: slot) }
            refreshSampling(pad, slot: slot)
            Diag.info("controller \(slot) \(Self.name(motionType)) reporting stopped (host request)",
                      Self.logCategory)
            return
        }

        // The caps gate means the host only asks for sensors we advertised,
        // but a pad detaching mid-flight reads nil here - then don't start.
        refreshSampling(pad, slot: slot)
        let detail = wasActive ? "retuned to" : "started at"
        Diag.info("controller \(slot) \(Self.name(motionType)) reporting \(detail) \(rate)Hz "
            + "(host requested \(reportRateHz))", Self.logCategory)
    }

    private func refreshSampling(_ pad: Pad, slot: UInt8) {
        pad.generation &+= 1
        let generation = pad.generation
        let token = pad.token
        let active = pad.inputEnabled && pad.rates.contains { $0 != 0 }
        pad.capture.setSensorsActive(active)
        guard active else { pad.capture.setHandler(nil); return }
        pad.capture.setHandler { [weak self] sample in
            self?.receive(slot: slot, token: token, generation: generation, sample: sample)
        }
    }

    /// One GCMotion change: convert each active sensor to the wire's SDL
    /// convention, skip unchanged readings, and send what the rate gate admits.
    private func receive(slot: UInt8, token: UUID, generation: UInt64, sample: ControllerMotionSample) {
        lock.lock(); defer { lock.unlock() }
        guard let pad = pads[slot], pad.inputEnabled, pad.token == token, pad.generation == generation,
              let backend = uplink else { return }
        let now = ProcessInfo.processInfo.systemUptime
        for motionType in [Self.accelType, Self.gyroType] {
            let idx = Int(motionType) - 1
            guard pad.rates[idx] != 0 else { continue }
            let value = Self.reading(sample, motionType)
            // Duplicate suppression (the moonlight-ios memcmp skip): a resting
            // pad would otherwise stream constants.
            if let last = pad.lastSample[idx], last == value { continue }
            guard pad.gates[idx].admit(at: now, rateHz: pad.rates[idx]) else { continue }
            let result = backend.sendControllerMotion(num: slot, motionType: motionType,
                                                      x: value.x, y: value.y, z: value.z)
            if result == 0 { pad.lastSample[idx] = value }
        }
    }

    private static func reading(_ motion: ControllerMotionSample, _ motionType: UInt8) -> (x: Float, y: Float, z: Float) {
        if motionType == accelType {
            // G (gravity DOWN at rest) → m/s^2 reaction-force convention
            // (+Y up at rest): one global -9.80665 (moonlight-ios mapping).
            let a = motion.acceleration
            return (Float(a.x) * -gravity, Float(a.y) * -gravity, Float(a.z) * -gravity)
        }
        // rad/s → deg/s with moonlight-ios's axis fix-up:
        // wire (x, y, z) = (rot.x, rot.z, -rot.y).
        let r = motion.rotation
        return (Float(r.x) * degPerRad, Float(r.z) * degPerRad, Float(r.y) * -degPerRad)
    }

    // MARK: - Halt helpers (main)

    /// Stop reporting both sensors. An active gyro sends one final zero sample so the host cannot retain
    /// an old turn rate.
    private func halt(pad: Pad, slot: UInt8, why: String) {
        guard pad.rates.contains(where: { $0 != 0 }) else { return }
        if pad.rates[Int(Self.gyroType) - 1] != 0 { sendGyroNull(slot: slot) }
        pad.generation &+= 1
        pad.capture.setHandler(nil)
        for idx in pad.rates.indices {
            pad.rates[idx] = 0
            pad.lastSample[idx] = nil
            pad.gates[idx] = MotionRateGate()
        }
        setSensorsActive(pad, false)
        Diag.info("controller \(slot) motion sampling stopped (\(why))", Self.logCategory)
    }

    /// The reliable gyro null-state sample (see halt()).
    private func sendGyroNull(slot: UInt8) {
        guard let backend = uplink else { return }
        _ = backend.sendControllerMotion(num: slot, motionType: Self.gyroType,
                                         x: 0, y: 0, z: 0)
    }

    /// Some pads gate their IMU behind explicit power-up; flip it with sensor
    /// liveness (the moonlight-ios sensorsRequireManualActivation discipline)
    /// so a motion-idle pad burns no sensor power.
    private func setSensorsActive(_ pad: Pad, _ active: Bool) {
        pad.capture.setSensorsActive(active)
    }

    /// Human label for a motion type in breadcrumbs.
    private static func name(_ motionType: UInt8) -> String {
        motionType == accelType ? "accel" : "gyro"
    }

    // MARK: - Per-pad state

    /// Registration and sampling hold the recursive lock for the full lifetime of each access.
    private final class Pad {
        /// Prepared capture closures retain only the native adapter lease.
        let capture: ControllerMotionCapture
        let token = UUID()
        var generation: UInt64 = 0
        var inputEnabled: Bool
        /// Granted report rate per sensor (index = LI_MOTION_TYPE_* - 1,
        /// post-cap); 0 = off.
        var rates: [UInt16] = [0, 0]
        /// Last forwarded sample per sensor, for duplicate suppression.
        var lastSample: [(x: Float, y: Float, z: Float)?] = [nil, nil]
        var gates = [MotionRateGate(), MotionRateGate()]

        init(capture: ControllerMotionCapture, inputEnabled: Bool) {
            self.capture = capture
            self.inputEnabled = inputEnabled
        }
    }
}

/// Caps forwarded samples at the host's rate without dropping a slower
/// pad's jittered ones: a two-sample token bucket refilled at `rateHz`.
package struct MotionRateGate: Equatable, Sendable {
    package init() {}
    private var tokens = 2.0
    private var lastAt: TimeInterval?

    package mutating func admit(at now: TimeInterval, rateHz: UInt16) -> Bool {
        if let lastAt { tokens = min(2, tokens + (now - lastAt) * Double(rateHz)) }
        lastAt = now
        guard tokens >= 1 else { return false }
        tokens -= 1
        return true
    }
}
