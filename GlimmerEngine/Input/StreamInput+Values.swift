// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

/// Positional gamepad buttons; capture adapters report physical positions, before layout mapping.
public struct ControllerButtons: OptionSet, Sendable, Hashable {
    public let rawValue: Int32
    public init(rawValue: Int32) { self.rawValue = rawValue }
    public static let a = Self(rawValue: StreamProtocol.A_FLAG)
    public static let b = Self(rawValue: StreamProtocol.B_FLAG)
    public static let x = Self(rawValue: StreamProtocol.X_FLAG)
    public static let y = Self(rawValue: StreamProtocol.Y_FLAG)
    public static let dpadUp = Self(rawValue: StreamProtocol.UP_FLAG)
    public static let dpadDown = Self(rawValue: StreamProtocol.DOWN_FLAG)
    public static let dpadLeft = Self(rawValue: StreamProtocol.LEFT_FLAG)
    public static let dpadRight = Self(rawValue: StreamProtocol.RIGHT_FLAG)
    public static let leftShoulder = Self(rawValue: StreamProtocol.LB_FLAG)
    public static let rightShoulder = Self(rawValue: StreamProtocol.RB_FLAG)
    public static let leftStick = Self(rawValue: StreamProtocol.LS_CLK_FLAG)
    public static let rightStick = Self(rawValue: StreamProtocol.RS_CLK_FLAG)
    public static let menu = Self(rawValue: StreamProtocol.PLAY_FLAG)
    public static let options = Self(rawValue: StreamProtocol.BACK_FLAG)
    public static let home = Self(rawValue: StreamProtocol.SPECIAL_FLAG)
    public static let share = Self(rawValue: StreamProtocol.MISC_FLAG)
    public static let touchpad = Self(rawValue: StreamProtocol.TOUCHPAD_FLAG)
}

/// GC touchpad axes: [-1,1], Y up; (0,0) denotes an absent contact, as in GameController.
public struct ControllerTouchpadSample: Sendable {
    public var primaryX: Float
    public var primaryY: Float
    public var secondaryX: Float
    public var secondaryY: Float
    public var clicked: Bool

    var sanitized: Self {
        func contact(_ x: Float, _ y: Float) -> (Float, Float) {
            guard x.isFinite, y.isFinite else { return (0, 0) }
            return (max(-1, min(1, x)), max(-1, min(1, y)))
        }
        let primary = contact(primaryX, primaryY)
        let secondary = contact(secondaryX, secondaryY)
        return Self(primaryX: primary.0, primaryY: primary.1,
                    secondaryX: secondary.0, secondaryY: secondary.1, clicked: clicked)
    }

    public init(primaryX: Float, primaryY: Float, secondaryX: Float, secondaryY: Float, clicked: Bool) {
        self.primaryX = primaryX
        self.primaryY = primaryY
        self.secondaryX = secondaryX
        self.secondaryY = secondaryY
        self.clicked = clicked
    }
}

/// One capture snapshot. Triggers use [0,1]; sticks use [-1,1] with Y up. Nonfinite axes become neutral.
public struct ControllerInputSample: Sendable {
    public var buttons: ControllerButtons
    public var leftTrigger: Float
    public var rightTrigger: Float
    public var leftStickX: Float
    public var leftStickY: Float
    public var rightStickX: Float
    public var rightStickY: Float
    public var touchpad: ControllerTouchpadSample?

    public init(buttons: ControllerButtons = [], leftTrigger: Float = 0, rightTrigger: Float = 0,
                leftStickX: Float = 0, leftStickY: Float = 0, rightStickX: Float = 0, rightStickY: Float = 0,
                touchpad: ControllerTouchpadSample? = nil) {
        self.buttons = buttons
        self.leftTrigger = leftTrigger
        self.rightTrigger = rightTrigger
        self.leftStickX = leftStickX
        self.leftStickY = leftStickY
        self.rightStickX = rightStickX
        self.rightStickY = rightStickY
        self.touchpad = touchpad
    }

    package static let triggerPressThreshold: UInt8 = 128

    package var analog: GamepadAnalog {
        Self.normalizedAnalog(((leftTrigger, rightTrigger), (leftStickX, leftStickY), (rightStickX, rightStickY)))
    }

    package static func normalizedAnalog(_ axes: ((Float, Float), (Float, Float), (Float, Float))) -> GamepadAnalog {
        func trigger(_ value: Float) -> UInt8 {
            value.isFinite ? UInt8(max(0, min(255, (value * 255).rounded()))) : 0
        }
        func axis(_ value: Float) -> Int16 {
            value.isFinite ? Int16(max(-32768, min(32767, (value * 32767).rounded()))) : 0
        }
        return GamepadAnalog(leftTrigger: trigger(axes.0.0), rightTrigger: trigger(axes.0.1),
            leftStickX: axis(axes.1.0), leftStickY: axis(axes.1.1),
            rightStickX: axis(axes.2.0), rightStickY: axis(axes.2.1))
    }
}

/// Opaque registration identity. Reusing a slot never makes an obsolete capture callback valid.
public struct ControllerRegistration: Sendable, Hashable {
    public let slot: UInt8
    package let token: UUID
    package init(slot: UInt8, token: UUID) { self.slot = slot; self.token = token }
}

public struct ControllerDescriptor: Sendable, Equatable {
    public enum Kind: UInt8, Sendable { case unknown = 0, xbox = 1, playStation = 2, nintendo = 3 }
    public struct Capabilities: OptionSet, Sendable, Hashable {
        public let rawValue: UInt16
        public init(rawValue: UInt16) { self.rawValue = rawValue }
        public static let analogTriggers = Self(rawValue: 0x01)
        public static let rumble = Self(rawValue: 0x02)
        public static let triggerRumble = Self(rawValue: 0x04)
        public static let touchpad = Self(rawValue: 0x08)
        public static let accelerometer = Self(rawValue: 0x10)
        public static let gyroscope = Self(rawValue: 0x20)
        public static let battery = Self(rawValue: 0x40)
        public static let rgbLED = Self(rawValue: 0x80)
    }
    public var kind: Kind
    public var supportedButtons: ControllerButtons
    public var capabilities: Capabilities
    public var useNintendoLabels: Bool

    public init(kind: Kind, supportedButtons: ControllerButtons, capabilities: Capabilities,
                useNintendoLabels: Bool = false) {
        self.kind = kind
        self.supportedButtons = supportedButtons
        self.capabilities = capabilities
        self.useNintendoLabels = useNintendoLabels
    }
}

public enum PointerButton: Int32, Sendable { case left = 1, middle = 2, right = 3, back = 4, forward = 5 }
