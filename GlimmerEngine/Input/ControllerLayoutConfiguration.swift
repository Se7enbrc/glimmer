// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

public struct ControllerLayoutConfiguration: Sendable {
    public let plan: ControllerMappingPlan?
    public let escape: ControllerPhysicalChord
    public let stop: ControllerPhysicalChord?

    public init(layout: ControllerLayout?, shortcuts: ControllerLayoutShortcuts?,
                available: Set<ControllerLayoutSource>, extras: [String] = []) throws {
        plan = try layout.map { try ControllerMappingPlan(layout: $0, available: available, extras: extras) }
        escape = try ControllerPhysicalChord(sources: ControllerLayoutShortcuts.escape(available: available), extras: extras)
        // Older libraries may contain custom shortcuts; they never override the protected stop chord.
        stop = try ControllerPhysicalChord(sources: ControllerLayoutShortcuts.fixedStop, extras: [])
    }
}

extension ControllerMappingSample {
    package init(buttons: Int32, analog: GamepadAnalog, extras: SIMD2<UInt64> = .zero) {
        self.init(buttons: UInt32(bitPattern: buttons), analog: SIMD8(
            Int32(analog.leftTrigger), Int32(analog.rightTrigger), Int32(analog.leftStickX), Int32(analog.leftStickY),
            Int32(analog.rightStickX), Int32(analog.rightStickY), 0, 0), extras: extras)
    }

    package var gamepadAnalog: GamepadAnalog {
        GamepadAnalog(leftTrigger: UInt8(clamping: analog[0]), rightTrigger: UInt8(clamping: analog[1]),
            leftStickX: Int16(clamping: analog[2]), leftStickY: Int16(clamping: analog[3]),
            rightStickX: Int16(clamping: analog[4]), rightStickY: Int16(clamping: analog[5]))
    }
}

public struct ControllerLayoutRearm: Sendable {
    private var blockedButtons: UInt32
    private var blockedExtras: SIMD2<UInt64>
    private var blockedAxes: UInt8 = 0

    public init(held: ControllerMappingSample) {
        blockedButtons = held.buttons
        blockedExtras = held.extras
        for index in 0..<6 where abs(Int64(held.analog[index])) > (index < 2 ? 51 : 6553) {
            blockedAxes |= 1 << index
        }
    }

    public var isNeutral: Bool { blockedButtons == 0 && blockedExtras == .zero && blockedAxes == 0 }

    public mutating func filter(_ sample: ControllerMappingSample) -> ControllerMappingSample {
        blockedButtons &= sample.buttons
        blockedExtras &= sample.extras
        var accepted = sample
        accepted.buttons &= ~blockedButtons
        accepted.extras &= ~blockedExtras
        for index in 0..<6 {
            if abs(Int64(sample.analog[index])) <= (index < 2 ? 51 : 6553) { blockedAxes &= ~(1 << index) }
            if blockedAxes & (1 << index) != 0 { accepted.analog[index] = 0 }
        }
        return accepted
    }
}
