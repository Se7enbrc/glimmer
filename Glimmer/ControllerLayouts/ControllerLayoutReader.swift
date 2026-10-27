// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GameController
import GlimmerEngine
import Synchronization

// References are immutable; GameController synchronizes live values and stream callbacks use one serial queue.
final class ControllerLayoutReader: @unchecked Sendable {
    let input: GCControllerLiveInput
    let identity: ControllerLayoutIdentity
    let controls: [ControllerLayoutControl]
    let extras: [String]
    let available: Set<ControllerLayoutSource>
    private let buttons: [(any GCPressedStateInput, UInt32)]
    private let extraButtons: [any GCPressedStateInput]
    private let triggers: [(any GCLinearInput, Int)]
    private let axes: [(any GCAxisInput, Int)]
    private let systemButtons: [(GCControllerButtonInput, UInt32)]
    private let systemTriggers: [GCControllerButtonInput]
    private let systemAxes: [GCControllerAxisInput]
    private let touchpads: (any GCDirectionPadElement, any GCDirectionPadElement)?

    init?(_ controller: GCController) {
        guard let input = controller.input.unmapped else { return nil }
        guard !input.buttons.isEmpty || !input.dpads.isEmpty else { return nil }
        self.input = input
        let discovery = Self.discover(input)
        buttons = discovery.buttons
        extraButtons = discovery.extraButtons
        triggers = discovery.triggers
        axes = discovery.axes
        controls = discovery.controls
        extras = discovery.extras
        available = Set(controls.map(\.id))
        var systemButtons = Self.standardButtons.compactMap { name, button -> (GCControllerButtonInput, UInt32)? in
            controller.physicalInputProfile.buttons[name].map { ($0, button.rawValue) }
        }
        if let pad = controller.extendedGamepad {
            systemButtons += [(pad.dpad.up, ControllerMappedButton.up.rawValue),
                              (pad.dpad.down, ControllerMappedButton.down.rawValue),
                              (pad.dpad.left, ControllerMappedButton.left.rawValue),
                              (pad.dpad.right, ControllerMappedButton.right.rawValue)]
            systemTriggers = [pad.leftTrigger, pad.rightTrigger]
            systemAxes = [pad.leftThumbstick.xAxis, pad.leftThumbstick.yAxis, pad.rightThumbstick.xAxis, pad.rightThumbstick.yAxis]
        } else {
            systemTriggers = []
            systemAxes = []
        }
        self.systemButtons = systemButtons
        if let primary = input.dpads[GCInputDualShockTouchpadOne], let secondary = input.dpads[GCInputDualShockTouchpadTwo] {
            touchpads = (primary, secondary)
        } else { touchpads = nil }
        identity = ControllerLayoutIdentity(category: controller.productCategory, profile: "physical",
                                            controls: controls.map { $0.id.identityName })
    }

    func sample() -> ControllerMappingSample {
        var result = ControllerMappingSample()
        for (input, mask) in buttons where input.isPressed { result.buttons |= mask }
        for index in extraButtons.indices where extraButtons[index].isPressed { result.setExtra(index, pressed: true) }
        for (input, index) in triggers {
            let value = input.value
            result.analog[index] = value.isFinite ? Int32(max(0, min(255, (value * 255).rounded()))) : 0
        }
        for (input, index) in axes {
            let value = input.value
            result.analog[index] = value.isFinite ? Int32(max(-32768, min(32767, (value * 32767).rounded()))) : 0
        }
        return result
    }

    func systemSample() -> ControllerMappingSample {
        var result = ControllerMappingSample()
        for (input, mask) in systemButtons where input.isPressed { result.buttons |= mask }
        for index in systemTriggers.indices {
            let value = systemTriggers[index].value
            result.analog[index] = value.isFinite ? Int32(max(0, min(255, (value * 255).rounded()))) : 0
        }
        for index in systemAxes.indices {
            let value = systemAxes[index].value
            result.analog[index + 2] = value.isFinite ? Int32(max(-32768, min(32767, (value * 32767).rounded()))) : 0
        }
        return result
    }

    func touchSample(clicked: Bool) -> ControllerTouchpadSample? {
        touchpads.map {
            .init(primaryX: $0.0.xAxis.value, primaryY: $0.0.yAxis.value,
                  secondaryX: $0.1.xAxis.value, secondaryY: $0.1.yAxis.value, clicked: clicked)
        }
    }

    func streamSample(_ physical: ControllerMappingSample, mapsGameInput: Bool) -> ControllerInputSample {
        let sample = mapsGameInput ? physical : systemSample()
        return ControllerInputSample(buttons: .init(rawValue: Int32(bitPattern: sample.buttons)),
            leftTrigger: Float(sample.analog[0]) / 255, rightTrigger: Float(sample.analog[1]) / 255,
            leftStickX: Float(sample.analog[2]) / 32767, leftStickY: Float(sample.analog[3]) / 32767,
            rightStickX: Float(sample.analog[4]) / 32767, rightStickY: Float(sample.analog[5]) / 32767,
            touchpad: touchSample(clicked: physical.buttons & ControllerMappedButton.touchpad.rawValue != 0),
            extraButtons: sample.extras, physicalSample: physical)
    }

    func shortcutElements(_ configuration: ControllerLayoutConfiguration) -> Set<ObjectIdentifier> {
        Set(Self.shortcutNames(configuration, extras: extras).compactMap { name in
            if let button = input.buttons[name] { return ObjectIdentifier(button) }
            if let dpad = input.dpads[name] { return ObjectIdentifier(dpad) }
            return nil
        })
    }

    static func shortcutNames(_ configuration: ControllerLayoutConfiguration, extras: [String]) -> Set<String> {
        let mouse = configuration.mouse?.observed ?? .empty
        let buttons = configuration.stop.buttons | configuration.stats.buttons | mouse.buttons
        let triggers = configuration.stop.triggers | configuration.stats.triggers | mouse.triggers
        let extraMask = configuration.stop.extras | configuration.stats.extras | mouse.extras
        var names = Set(standardButtons.filter { buttons & $0.1.rawValue != 0 }.map(\.0))
        for (index, name) in [GCInputLeftTrigger, GCInputRightTrigger].enumerated() where triggers & (1 << index) != 0 {
            names.insert(name)
        }
        for (index, name) in extras.enumerated() where extraMask[index / 64] & (1 << (index % 64)) != 0 {
            names.insert(name)
        }
        let directions: UInt32 = ControllerMappedButton.up.rawValue | ControllerMappedButton.down.rawValue
            | ControllerMappedButton.left.rawValue | ControllerMappedButton.right.rawValue
        if buttons & directions != 0 { names.insert(GCInputDirectionPad) }
        // System-profile callbacks already sample physical sticks; custom layouts observe every physical element.
        return names
    }

    private struct Discovery {
        var buttons: [(any GCPressedStateInput, UInt32)] = []
        var extraButtons: [any GCPressedStateInput] = []
        var triggers: [(any GCLinearInput, Int)] = []
        var axes: [(any GCAxisInput, Int)] = []
        var controls: [ControllerLayoutControl] = []
        var extras: [String] = []

        mutating func add(_ source: ControllerLayoutSource, element: any GCPhysicalInputElement) {
            controls.append(.init(id: source, name: element.localizedName ?? source.layoutName,
                                  symbol: element.sfSymbolsName ?? source.layoutSymbol,
                                  position: ControllerLayoutReader.position(aliases: element.aliases)))
        }
    }

    static func position(aliases: Set<String>) -> ControllerLayoutControl.Position? {
        let positions: [(GCButtonElementName, ControllerLayoutControl.Position)] = [
            (.backLeftButton(position: 0), .backLeftPrimary), (.backRightButton(position: 0), .backRightPrimary),
            (.backLeftButton(position: 1), .backLeftSecondary), (.backRightButton(position: 1), .backRightSecondary),
            (.leftBumper, .topLeftInner), (.rightBumper, .topRightInner)
        ]
        return positions.first { aliases.contains($0.0.rawValue) }?.1
    }

    private static func discover(_ input: GCControllerLiveInput) -> Discovery {
        var result = Discovery()
        var seen: Set<ObjectIdentifier> = []
        for (name, button) in standardButtons {
            guard let element = input.buttons[name], seen.insert(ObjectIdentifier(element)).inserted else { continue }
            result.buttons.append((element.pressedInput, button.rawValue))
            result.add(.button(button), element: element)
        }
        for (name, trigger) in [(GCInputLeftTrigger, ControllerMappedTrigger.left), (GCInputRightTrigger, .right)] {
            guard let element = input.buttons[name], seen.insert(ObjectIdentifier(element)).inserted else { continue }
            result.triggers.append((element.pressedInput, trigger.rawValue))
            result.add(.trigger(trigger), element: element)
        }
        for element in input.buttons where !seen.contains(ObjectIdentifier(element)) {
            guard let name = element.aliases.min(), result.extras.count < 128 else { continue }
            seen.insert(ObjectIdentifier(element))
            result.extras.append(name)
            result.extraButtons.append(element.pressedInput)
            result.add(.extra(name), element: element)
        }
        addDirections(input, to: &result)
        return result
    }

    private static func addDirections(_ input: GCControllerLiveInput, to result: inout Discovery) {
        if let dpad = input.dpads[GCInputDirectionPad] {
            let directions: [(any GCPressedStateInput, ControllerMappedButton)] = [
                (dpad.up, .up), (dpad.down, .down), (dpad.left, .left), (dpad.right, .right)
            ]
            for (pressed, button) in directions {
                result.buttons.append((pressed, button.rawValue))
                result.controls.append(.init(id: .button(button), name: button.layoutName, symbol: button.layoutSymbol))
            }
        }
        let sticks: [(String, ControllerMappedAxis, ControllerMappedAxis)] = [
            (GCInputLeftThumbstick, .leftX, .leftY), (GCInputRightThumbstick, .rightX, .rightY)
        ]
        for (name, horizontal, vertical) in sticks {
            guard let stick = input.dpads[name] else { continue }
            result.axes += [(stick.xAxis, horizontal.rawValue), (stick.yAxis, vertical.rawValue)]
            for axis in [horizontal, vertical] {
                result.controls.append(.init(id: .axis(axis), name: axis.layoutName, symbol: "l.joystick"))
                for positive in [false, true] {
                    let source = ControllerLayoutSource.direction(axis, positive: positive)
                    result.controls.append(.init(id: source, name: source.layoutName, symbol: "l.joystick"))
                }
            }
        }
    }

    private static let standardButtons: [(String, ControllerMappedButton)] = [
        (GCInputButtonA, .a), (GCInputButtonB, .b), (GCInputButtonX, .x), (GCInputButtonY, .y),
        (GCInputButtonMenu, .menu), (GCInputButtonOptions, .options), (GCInputButtonHome, .home),
        (GCInputLeftShoulder, .leftShoulder), (GCInputRightShoulder, .rightShoulder),
        (GCInputLeftThumbstickButton, .leftStick), (GCInputRightThumbstickButton, .rightStick),
        (GCInputButtonShare, .share), (GCInputDualShockTouchpadButton, .touchpad),
        (GCInputXboxPaddleOne, .paddle1), (GCInputXboxPaddleTwo, .paddle2),
        (GCInputXboxPaddleThree, .paddle3), (GCInputXboxPaddleFour, .paddle4)
    ]
}

// Installs the stream's callbacks directly; registration validity belongs to the owning forwarder.
@MainActor
enum ControllerStreamHandlers {
    static func install(controller: GCController, input: GCControllerLiveInput, queue: DispatchQueue,
                        mapsGameInput: Bool, shortcutElements: Set<ObjectIdentifier>,
                        read: @escaping @Sendable () -> ControllerMappingSample,
                        receive: @escaping @Sendable (ControllerMappingSample, TimeInterval) -> Void) {
        controller.extendedGamepad?.valueChangedHandler = nil
        input.elementValueDidChangeHandler = nil
        controller.handlerQueue = queue
        input.queue = queue
        let timestamp = Mutex<TimeInterval>(0)
        let deliver: @Sendable (TimeInterval) -> Void = { value in
            let now = timestamp.withLock { last in
                last = max(last, value)
                return last
            }
            receive(read(), now)
        }
        if mapsGameInput || !shortcutElements.isEmpty {
            input.elementValueDidChangeHandler = { @Sendable input, element in
                guard mapsGameInput || shortcutElements.contains(ObjectIdentifier(element)) else { return }
                deliver(ProcessInfo.processInfo.systemUptime - max(0, input.lastEventLatency))
            }
        }
        if !mapsGameInput {
            controller.extendedGamepad?.valueChangedHandler = { @Sendable pad, _ in deliver(pad.lastEventTimestamp) }
        }
    }
}
