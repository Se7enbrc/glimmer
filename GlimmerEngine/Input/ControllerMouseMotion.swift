// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

package struct ControllerMouseMotion {
    private var remainder = SIMD2<Double>.zero

    package static func velocity(x: Int16, y: Int16) -> SIMD2<Double> {
        let vector = SIMD2(Double(x) / 32767, Double(y) / 32767)
        let length = hypot(vector.x, vector.y)
        guard length > 0.15 else { return .zero }
        let travel = (min(1, length) - 0.15) / 0.85
        return vector / length * (1240 * travel * travel)
    }

    package mutating func step(x: Int16, y: Int16, seconds: Double) -> SIMD2<Int16> {
        let velocity = Self.velocity(x: x, y: y)
        guard velocity != .zero, seconds.isFinite, seconds > 0 else {
            remainder = .zero
            return .zero
        }
        // Bound stalls so returning from a delayed tick cannot fling the pointer.
        remainder += velocity * min(seconds, 0.05)
        let delta = SIMD2(Int16(remainder.x.rounded(.towardZero)), Int16(remainder.y.rounded(.towardZero)))
        remainder -= SIMD2(Double(delta.x), Double(delta.y))
        return delta
    }
}

#if os(iOS)
extension ControllerMouseState {
    mutating func resetIdleMotion(rightPointer: Bool) {
        let pointer = rightPointer ? (analog.rightStickX, analog.rightStickY) : (analog.leftStickX, analog.leftStickY)
        let scroll = rightPointer ? (analog.leftStickX, analog.leftStickY) : (analog.rightStickX, analog.rightStickY)
        let pointerIdle = ControllerMouseMotion.velocity(x: pointer.0, y: pointer.1) == .zero
        let scrollIdle = ControllerMouseMotion.velocity(x: scroll.0, y: scroll.1) == .zero
        if pointerIdle || !isMouse { pointerMotion = ControllerMouseMotion() }
        if scrollIdle || !isMouse { scrollMotion = ControllerMouseMotion() }
        if (pointerIdle && scrollIdle) || !isMouse { sampledAt = nil }
    }

    mutating func sampleMotion(rightPointer: Bool, now: TimeInterval)
        -> (pointer: SIMD2<Int16>, scroll: SIMD2<Int16>) {
        let seconds = sampledAt.map { now - $0 } ?? InputCore.controllerMousePollInterval
        sampledAt = now
        return (
            pointerMotion.step(x: rightPointer ? analog.rightStickX : analog.leftStickX,
                               y: rightPointer ? analog.rightStickY : analog.leftStickY, seconds: seconds),
            scrollMotion.step(x: rightPointer ? analog.leftStickX : analog.rightStickX,
                              y: rightPointer ? analog.leftStickY : analog.rightStickY, seconds: seconds))
    }
}
#endif
