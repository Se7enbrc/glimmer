// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

public struct ControllerMappingPlan: Sendable {
    private enum Source: Sendable {
        case button(UInt32), extra(Int), trigger(Int), axis(Int), direction(Int, Int32)

        func value(_ sample: ControllerMappingSample) -> Int32 {
            switch self {
            case .button(let mask): sample.buttons & mask == 0 ? 0 : 255
            case .extra(let index): sample.extras[index / 64] & (1 << (index % 64)) == 0 ? 0 : 255
            case .trigger(let index): max(0, min(255, sample.analog[index]))
            case .axis(let index): max(-32768, min(32767, sample.analog[index]))
            case .direction(let index, let sign): max(0, min(32767, max(-32768, min(32767, sample.analog[index])) * sign))
            }
        }

        var thresholds: (press: Int32, release: Int32) {
            switch self {
            case .direction: (16384, 14745)
            case .trigger: (128, 115)
            default: (1, 0)
            }
        }
    }

    private struct Operation: Sendable {
        let source: Source
        let destination: ControllerLayoutDestination
    }

    private let operations: [Operation]
    private var held = SIMD4<UInt64>.zero
    public let supportedButtons: UInt32
    public let unavailableSources: Set<ControllerLayoutSource>

    public init(layout: ControllerLayout, available: Set<ControllerLayoutSource>, extras: [String] = []) throws {
        try layout.validate()
        guard extras.count <= 128, Set(extras).count == extras.count else {
            throw ControllerLayoutError.invalidBindings
        }
        var operations: [Operation] = []
        var unavailable: Set<ControllerLayoutSource> = []
        var buttons: UInt32 = 0
        for binding in layout.bindings where binding.destination != .disabled {
            guard available.contains(binding.source), let source = Self.source(binding.source, extras: extras) else {
                unavailable.insert(binding.source)
                continue
            }
            operations.append(Operation(source: source, destination: binding.destination))
            if case .button(let button) = binding.destination { buttons |= button.rawValue }
        }
        self.operations = operations
        supportedButtons = buttons
        unavailableSources = unavailable
    }

    public mutating func apply(_ sample: ControllerMappingSample) -> ControllerMappingSample {
        var result = ControllerMappingSample()
        for index in operations.indices {
            let operation = operations[index]
            let value = operation.source.value(sample)
            let thresholds = operation.source.thresholds
            let mask = UInt64(1) << (index % 64)
            let wasHeld = held[index / 64] & mask != 0
            let pressed = wasHeld ? value > thresholds.release : value >= thresholds.press
            if pressed { held[index / 64] |= mask } else { held[index / 64] &= ~mask }
            Self.accumulate(operation, value: value, pressed: pressed, into: &result)
        }
        for index in 2..<6 { result.analog[index] = max(-32768, min(32767, result.analog[index])) }
        return result
    }

    public mutating func reset() { held = .zero }

    private static func accumulate(_ operation: Operation, value: Int32, pressed: Bool,
                                   into result: inout ControllerMappingSample) {
        switch operation.destination {
        case .button(let button):
            if pressed { result.buttons |= button.rawValue }
        case .trigger(let trigger):
            let amount: Int32
            if case .trigger = operation.source { amount = value } else { amount = pressed ? 255 : 0 }
            result.analog[trigger.rawValue] = max(result.analog[trigger.rawValue], amount)
        case .axis(let axis, let inverted):
            result.analog[axis.rawValue] += inverted ? -value : value
        case .direction(let axis, let positive):
            if pressed { result.analog[axis.rawValue] += positive ? 32767 : -32767 }
        case .disabled: break
        }
    }

    private static func source(_ source: ControllerLayoutSource, extras: [String]) -> Source? {
        switch source {
        case .button(let button): .button(button.rawValue)
        case .extra(let name): extras.firstIndex(of: name).map { .extra($0) }
        case .trigger(let trigger): .trigger(trigger.rawValue)
        case .axis(let axis): .axis(axis.rawValue)
        case .direction(let axis, let positive): .direction(axis.rawValue, positive ? 1 : -1)
        }
    }
}
