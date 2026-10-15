// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import GameController
import GlimmerEngine

extension ControllerMotion {
    static let shared = ControllerMotion()

    func register(slot: UInt8, controller: GCController, inputEnabled: Bool) -> UInt16 {
        register(slot: slot, capture: MacControllerMotion(controller).capture(), inputEnabled: inputEnabled)
    }
}

/// Native sensor access; the weak device is read only on GameController and serialized lifecycle callbacks.
private final class MacControllerMotion: @unchecked Sendable {
    private weak var controller: GCController?
    init(_ controller: GCController) { self.controller = controller }

    func capture() -> ControllerMotionCapture {
        ControllerMotionCapture(hasAcceleration: controller?.motion?.hasGravityAndUserAcceleration == true,
            hasRotation: controller?.motion?.hasRotationRate == true, read: { [self] in read() },
            setHandler: { [self] handler in
                guard let motion = controller?.motion else { return }
                guard let handler else { motion.valueChangedHandler = nil; return }
                motion.valueChangedHandler = { [self] _ in
                    guard let sample = read() else { return }
                    handler(sample)
                }
            }, setSensorsActive: { [self] active in
                guard let motion = controller?.motion, motion.sensorsRequireManualActivation else { return }
                motion.sensorsActive = active
            })
    }

    private func read() -> ControllerMotionSample? {
        guard let motion = controller?.motion else { return nil }
        let a = motion.acceleration
        let r = motion.rotationRate
        return ControllerMotionSample(acceleration: SIMD3(Float(a.x), Float(a.y), Float(a.z)),
            rotation: SIMD3(Float(r.x), Float(r.y), Float(r.z)))
    }
}
