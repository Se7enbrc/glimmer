// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

#if DEBUG
import GameController
import GlimmerEngine

// Public snapshot devices expose only the legacy profile. These physical-input values read those same GC elements.
final class JourneyButtonInput: NSObject, GCPressedStateInput, GCLinearInput {
    private let button: GCControllerButtonInput
    init(_ button: GCControllerButtonInput) { self.button = button }
    var isPressed: Bool { button.isPressed }
    var value: Float { button.value }
    var isAnalog: Bool { true }
    var canWrap: Bool { false }
    var sources: Set<AnyHashable> { [] }
    @available(iOS 26.2, macOS 26.2, *)
    var physicalExtents: (any GCPhysicalInputExtents)? { nil }
    var lastPressedStateTimestamp: TimeInterval { ProcessInfo.processInfo.systemUptime }
    var lastPressedStateLatency: TimeInterval { 0 }
    var lastValueTimestamp: TimeInterval { ProcessInfo.processInfo.systemUptime }
    var lastValueLatency: TimeInterval { 0 }
    var pressedDidChangeHandler: ((any GCPhysicalInputElement, any GCPressedStateInput, Bool) -> Void)?
    var valueDidChangeHandler: ((any GCPhysicalInputElement, any GCLinearInput, Float) -> Void)?
}

final class JourneyAxisInput: NSObject, GCAxisInput {
    private let axis: GCControllerAxisInput
    init(_ axis: GCControllerAxisInput) { self.axis = axis }
    var value: Float { axis.value }
    var isAnalog: Bool { true }
    var canWrap: Bool { false }
    var sources: Set<AnyHashable> { [] }
    var lastValueTimestamp: TimeInterval { ProcessInfo.processInfo.systemUptime }
    var lastValueLatency: TimeInterval { 0 }
    var valueDidChangeHandler: ((any GCPhysicalInputElement, any GCAxisInput, Float) -> Void)?
}

extension ControllerLayoutReader {
    static func journeyDiscovery(_ controller: JourneySnapshotController) -> Discovery {
        var result = Discovery()
        guard let pad = controller.extendedGamepad else { return result }
        let buttons: [(GCControllerButtonInput?, ControllerMappedButton)] = [
            (pad.buttonA, .a), (pad.buttonB, .b), (pad.buttonX, .x), (pad.buttonY, .y),
            (pad.leftShoulder, .leftShoulder), (pad.rightShoulder, .rightShoulder),
            (pad.leftThumbstickButton, .leftStick), (pad.rightThumbstickButton, .rightStick),
            (pad.buttonMenu, .menu), (pad.buttonOptions, .options),
            (pad.dpad.up, .up), (pad.dpad.down, .down), (pad.dpad.left, .left), (pad.dpad.right, .right)
        ]
        for (button, source) in buttons {
            guard let button else { continue }
            result.buttons.append((JourneyButtonInput(button), source.rawValue))
            result.controls.append(.init(id: .button(source), name: button.localizedName ?? source.layoutName,
                                         symbol: button.sfSymbolsName ?? source.layoutSymbol))
        }
        for (button, trigger) in [(pad.leftTrigger, ControllerMappedTrigger.left), (pad.rightTrigger, .right)] {
            result.triggers.append((JourneyButtonInput(button), trigger.rawValue))
            let source = ControllerLayoutSource.trigger(trigger)
            result.controls.append(.init(id: source, name: source.layoutName, symbol: source.layoutSymbol))
        }
        for (stick, horizontal, vertical) in [(pad.leftThumbstick, ControllerMappedAxis.leftX, ControllerMappedAxis.leftY),
                                              (pad.rightThumbstick, ControllerMappedAxis.rightX, ControllerMappedAxis.rightY)] {
            result.axes += [(JourneyAxisInput(stick.xAxis), horizontal.rawValue),
                            (JourneyAxisInput(stick.yAxis), vertical.rawValue)]
            for axis in [horizontal, vertical] {
                let source = ControllerLayoutSource.axis(axis)
                result.controls.append(.init(id: source, name: source.layoutName, symbol: source.layoutSymbol))
                for positive in [false, true] {
                    let direction = ControllerLayoutSource.direction(axis, positive: positive)
                    result.controls.append(.init(id: direction, name: direction.layoutName, symbol: direction.layoutSymbol))
                }
            }
        }
        return result
    }
}
#endif
