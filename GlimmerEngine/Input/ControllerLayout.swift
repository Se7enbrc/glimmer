// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

public enum ControllerMappedButton: UInt32, CaseIterable, Codable, Sendable {
    case up = 0x0001, down = 0x0002, left = 0x0004, right = 0x0008
    case menu = 0x0010, options = 0x0020, leftStick = 0x0040, rightStick = 0x0080
    case leftShoulder = 0x0100, rightShoulder = 0x0200, home = 0x0400
    case a = 0x1000, b = 0x2000, x = 0x4000, y = 0x8000
    case paddle1 = 0x01_0000, paddle2 = 0x02_0000, paddle3 = 0x04_0000, paddle4 = 0x08_0000
    case touchpad = 0x10_0000, share = 0x20_0000
}

public enum ControllerMappedTrigger: Int, CaseIterable, Codable, Sendable { case left, right }
public enum ControllerMappedAxis: Int, CaseIterable, Codable, Sendable { case leftX = 2, leftY, rightX, rightY }

public enum ControllerLayoutSource: Hashable, Codable, Sendable {
    case button(ControllerMappedButton)
    case extra(String)
    case trigger(ControllerMappedTrigger)
    case axis(ControllerMappedAxis)
    case direction(ControllerMappedAxis, positive: Bool)
}

public enum ControllerLayoutDestination: Hashable, Codable, Sendable {
    case button(ControllerMappedButton)
    case trigger(ControllerMappedTrigger)
    case axis(ControllerMappedAxis, inverted: Bool)
    case direction(ControllerMappedAxis, positive: Bool)
    case disabled
}

public struct ControllerLayoutBinding: Equatable, Codable, Sendable {
    public let source: ControllerLayoutSource
    public var destination: ControllerLayoutDestination

    public init(_ source: ControllerLayoutSource, _ destination: ControllerLayoutDestination) {
        self.source = source
        self.destination = destination
    }
}

public struct ControllerLayoutControl: Identifiable, Hashable, Codable, Sendable {
    public enum Position: String, Codable, Sendable {
        case backLeftPrimary, backRightPrimary, backLeftSecondary, backRightSecondary
        case topLeftInner, topRightInner
    }

    public let id: ControllerLayoutSource
    public let name: String
    public let symbol: String
    public let position: Position?

    public init(id: ControllerLayoutSource, name: String, symbol: String, position: Position? = nil) {
        self.id = id
        self.name = name
        self.symbol = symbol
        self.position = position
    }
}

public struct ControllerLayout: Equatable, Codable, Sendable {
    public var bindings: [ControllerLayoutBinding]

    public init(bindings: [ControllerLayoutBinding]) { self.bindings = bindings }

    public static func standard(buttons: [ControllerMappedButton], extras: [String] = [],
                                nintendoLabels: Bool = false) -> Self {
        let faces: [ControllerMappedButton: ControllerMappedButton] = [.a: .b, .b: .a, .x: .y, .y: .x]
        var bindings = buttons.map {
            ControllerLayoutBinding(.button($0), .button(nintendoLabels ? faces[$0] ?? $0 : $0))
        }
        bindings += extras.map { .init(.extra($0), .disabled) }
        bindings += ControllerMappedTrigger.allCases.map { .init(.trigger($0), .trigger($0)) }
        bindings += ControllerMappedAxis.allCases.map { .init(.axis($0), .axis($0, inverted: false)) }
        return Self(bindings: bindings)
    }

    public mutating func assign(_ source: ControllerLayoutSource, to destination: ControllerLayoutDestination) {
        if let index = bindings.firstIndex(where: { $0.source == source }) {
            bindings[index].destination = destination
        } else {
            bindings.append(.init(source, destination))
        }
    }

    public func validate() throws {
        guard bindings.count <= 256, Set(bindings.map(\.source)).count == bindings.count else {
            throw ControllerLayoutError.invalidBindings
        }
        for binding in bindings {
            if case .extra(let name) = binding.source, name.isEmpty || name.utf8.count > 256 {
                throw ControllerLayoutError.invalidBindings
            }
            if case .axis = binding.source {
                guard case .axis = binding.destination else {
                    if binding.destination == .disabled { continue }
                    throw ControllerLayoutError.invalidBindings
                }
            } else if case .axis = binding.destination {
                throw ControllerLayoutError.invalidBindings
            }
        }
        let fullAxes = bindings.compactMap { binding -> ControllerMappedAxis? in
            guard case .axis(let axis) = binding.source, binding.destination != .disabled else { return nil }
            return axis
        }
        for axis in fullAxes where bindings.contains(where: {
            if case .direction(let source, _) = $0.source { return source == axis && $0.destination != .disabled }
            return false
        }) { throw ControllerLayoutError.invalidBindings }
    }
}

public enum ControllerLayoutError: Error, Equatable, Sendable {
    case invalidBindings, invalidIdentity, invalidDocument, unsupportedVersion, tooLarge
}

public struct ControllerMappingSample: Equatable, Sendable {
    public var buttons: UInt32
    public var analog: SIMD8<Int32>
    public var extras: SIMD2<UInt64>

    public init(buttons: UInt32 = 0, analog: SIMD8<Int32> = .zero, extras: SIMD2<UInt64> = .zero) {
        self.buttons = buttons
        self.analog = analog
        self.extras = extras
    }

    public mutating func setExtra(_ index: Int, pressed: Bool) {
        guard (0..<128).contains(index) else { return }
        let mask = UInt64(1) << (index % 64)
        if pressed { extras[index / 64] |= mask } else { extras[index / 64] &= ~mask }
    }
}
