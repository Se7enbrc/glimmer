// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

public struct ControllerMousePlan: Sendable {
    let pointer: Int?
    let scroll: Int?
    let primary: ControllerPhysicalChord
    let secondary: ControllerPhysicalChord
    let middle: ControllerPhysicalChord
    let back: ControllerPhysicalChord
    let forward: ControllerPhysicalChord
    let toggle: ControllerPhysicalChord
    public let observed: ControllerPhysicalChord

    public init(_ bindings: ControllerMouseBindings = .init(), extras: [String] = [],
                shortcuts: ControllerLayoutShortcuts? = nil) {
        let bindings = shortcuts.map { bindings.resolving($0) } ?? bindings
        func chord(_ action: ControllerMouseAction) -> ControllerPhysicalChord {
            let sources = bindings[action]
            guard sources.allSatisfy(\.isMouseButton) else { return .empty }
            return (try? ControllerPhysicalChord(sources: sources, extras: extras)) ?? .empty
        }
        func axis(_ action: ControllerMouseAction) -> Int? {
            let sources = bindings[action]
            if sources == ControllerMouseMapping.stick(right: true) { return 4 }
            if sources == ControllerMouseMapping.stick(right: false) { return 2 }
            return nil
        }
        pointer = axis(.pointer)
        scroll = axis(.scroll)
        primary = chord(.primary)
        secondary = chord(.secondary)
        middle = chord(.middle)
        back = chord(.back)
        forward = chord(.forward)
        toggle = chord(.toggle)
        let sources = ControllerMouseAction.allCases.filter { !$0.isStick }
            .reduce(into: Set<ControllerLayoutSource>()) { $0.formUnion(bindings[$1]) }
        let supported = sources.filter { source in
            guard source.isMouseButton else { return false }
            if case .extra(let name) = source { return extras.contains(name) }
            return true
        }
        observed = (try? ControllerPhysicalChord(sources: supported, extras: extras)) ?? .empty
    }

    func clickMask(_ sample: ControllerMappingSample) -> UInt8 {
        (primary.held(in: sample) ? 1 : 0) | (secondary.held(in: sample) ? 2 : 0)
            | (middle.held(in: sample) ? 4 : 0) | (back.held(in: sample) ? 8 : 0) | (forward.held(in: sample) ? 16 : 0)
    }

    func clicks(_ mask: UInt8) -> Set<Int32> {
        var result = Set<Int32>()
        if mask & 1 != 0 { result.insert(StreamProtocol.BUTTON_LEFT) }
        if mask & 2 != 0 { result.insert(StreamProtocol.BUTTON_RIGHT) }
        if mask & 4 != 0 { result.insert(StreamProtocol.BUTTON_MIDDLE) }
        if mask & 8 != 0 { result.insert(StreamProtocol.BUTTON_X1) }
        if mask & 16 != 0 { result.insert(StreamProtocol.BUTTON_X2) }
        return result
    }

    func sticks(_ analog: GamepadAnalog) -> (pointer: SIMD2<Int16>, scroll: SIMD2<Int16>) {
        func stick(_ index: Int?) -> SIMD2<Int16> {
            guard let index else { return .zero }
            return index == 4 ? SIMD2(analog.rightStickX, analog.rightStickY) : SIMD2(analog.leftStickX, analog.leftStickY)
        }
        return (stick(pointer), stick(scroll))
    }
}

package struct ControllerMouseMotion {
    private var remainder = SIMD2<Double>.zero

    package init() {}

    package static func velocity(_ stick: SIMD2<Int16>) -> SIMD2<Double> {
        let vector = SIMD2(Double(stick.x) / 32767, Double(stick.y) / 32767)
        let length = hypot(vector.x, vector.y)
        guard length > 0.15 else { return .zero }
        let travel = (min(1, length) - 0.15) / 0.85
        return vector / length * (1240 * travel * travel)
    }

    package mutating func step(_ stick: SIMD2<Int16>, seconds: Double) -> SIMD2<Int16> {
        let velocity = Self.velocity(stick)
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
