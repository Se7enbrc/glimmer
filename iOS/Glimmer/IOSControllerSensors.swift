// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GameController
import GlimmerEngine

/// Native sensor ownership is guarded across the shared lifecycle and GameController callback threads.
final class IOSControllerMotion: @unchecked Sendable {
    private weak var motion: GCMotion?
    private let lock = NSRecursiveLock()
    private let priorHandler: GCMotionValueChangedHandler?
    private let priorSensorsActive: Bool
    private var active = true
    private var generation: UInt64 = 0

    init(_ motion: GCMotion?) {
        self.motion = motion
        priorHandler = motion?.valueChangedHandler
        priorSensorsActive = motion?.sensorsActive ?? false
    }

    func output() -> ControllerMotionCapture {
        ControllerMotionCapture(hasAcceleration: motion?.hasGravityAndUserAcceleration == true,
            hasRotation: motion?.hasRotationRate == true, read: { [self] in read() },
            setHandler: { [self] in setHandler($0) }, setSensorsActive: { [self] in setSensorsActive($0) })
    }

    func read() -> ControllerMotionSample? {
        lock.withLock {
            guard active, let motion else { return nil }
            let a = motion.acceleration
            let r = motion.rotationRate
            return ControllerMotionSample(acceleration: SIMD3(Float(a.x), Float(a.y), Float(a.z)),
                                          rotation: SIMD3(Float(r.x), Float(r.y), Float(r.z)))
        }
    }

    func setHandler(_ handler: (@Sendable (ControllerMotionSample) -> Void)?) {
        lock.withLock {
            guard active, let motion else { return }
            generation &+= 1
            let attempt = generation
            guard let handler else { motion.valueChangedHandler = nil; return }
            motion.valueChangedHandler = { [weak self] _ in
                guard let self else { return }
                let sample = self.lock.withLock {
                    self.generation == attempt ? self.read() : nil
                }
                if let sample { handler(sample) }
            }
        }
    }

    func setSensorsActive(_ enabled: Bool) {
        lock.withLock {
            guard active, let motion, motion.sensorsRequireManualActivation else { return }
            motion.sensorsActive = enabled
        }
    }

    func invalidate() {
        lock.withLock {
            guard active else { return }
            active = false
            generation &+= 1
            motion?.valueChangedHandler = priorHandler
            if motion?.sensorsRequireManualActivation == true { motion?.sensorsActive = priorSensorsActive }
        }
    }
}

@MainActor
enum IOSControllerBattery {
    static func capture(_ controller: GCController) -> ControllerBatteryCapture? {
        guard controller.battery != nil else { return nil }
        return ControllerBatteryCapture { [weak controller] in
            guard let battery = controller?.battery else { return nil }
            return sample(state: battery.batteryState, level: battery.batteryLevel)
        }
    }

    static func sample(state: GCDeviceBattery.State, level: Float) -> ControllerBatterySample {
        let value: ControllerBatterySample.State
        switch state {
        case .full: value = .full
        case .charging: value = .charging
        case .discharging: value = .discharging
        default: value = .unknown
        }
        return ControllerBatterySample(state: value, level: level)
    }
}
