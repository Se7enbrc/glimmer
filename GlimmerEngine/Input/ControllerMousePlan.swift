// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

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

    func motion(_ analog: GamepadAnalog) -> (pointer: SIMD2<Int16>, scroll: SIMD2<Int16>) {
        func delta(_ index: Int?) -> SIMD2<Int16> {
            guard let index else { return .zero }
            let right = index == 4
            return SIMD2(InputCore.controllerMouseDelta(right ? analog.rightStickX : analog.leftStickX),
                         InputCore.controllerMouseDelta(right ? analog.rightStickY : analog.leftStickY))
        }
        return (delta(pointer), delta(scroll))
    }
}
