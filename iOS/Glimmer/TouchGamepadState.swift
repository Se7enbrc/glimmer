// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import Foundation

struct TouchGamepadState {
    struct Contact: Equatable {
        let element: TouchElement
        let generation: UInt64
    }
    private(set) var sample = ControllerInputSample()
    private var owners: [TouchElement: Contact] = [:]
    private var generation: UInt64 = 0

    mutating func begin(_ element: TouchElement) -> Contact? {
        guard owners[element] == nil else { return nil }
        generation &+= 1
        let contact = Contact(element: element, generation: generation)
        owners[element] = contact
        return contact
    }

    mutating func update(_ contact: Contact, value: CGPoint) -> Bool {
        guard owners[contact.element] == contact, value.x.isFinite, value.y.isFinite else { return false }
        let previous = sample
        apply(contact.element, value: value)
        return !Self.equal(previous, sample)
    }

    mutating func end(_ contact: Contact) -> Bool {
        guard owners[contact.element] == contact else { return false }
        let changed = update(contact, value: .zero)
        owners.removeValue(forKey: contact.element)
        return changed
    }

    mutating func reset() {
        owners.removeAll(keepingCapacity: true)
        sample = ControllerInputSample()
    }

    private mutating func apply(_ element: TouchElement, value: CGPoint) {
        switch element {
        case .leftStick: sample.leftStickX = Float(value.x); sample.leftStickY = Float(value.y)
        case .rightStick: sample.rightStickX = Float(value.x); sample.rightStickY = Float(value.y)
        case .leftTrigger: sample.leftTrigger = Float(max(0, min(1, value.x)))
        case .rightTrigger: sample.rightTrigger = Float(max(0, min(1, value.x)))
        case .dpad:
            sample.buttons.subtract([.dpadUp, .dpadDown, .dpadLeft, .dpadRight])
            if value.y > 0 { sample.buttons.insert(.dpadUp) }
            if value.y < 0 { sample.buttons.insert(.dpadDown) }
            if value.x < 0 { sample.buttons.insert(.dpadLeft) }
            if value.x > 0 { sample.buttons.insert(.dpadRight) }
        default:
            if value.x > 0 { sample.buttons.formUnion(element.button) } else { sample.buttons.subtract(element.button) }
        }
    }

    static func stick(location: CGPoint, size: CGSize) -> CGPoint {
        let travel = min(size.width, size.height) * 0.3
        guard travel > 0, location.x.isFinite, location.y.isFinite else { return .zero }
        let x = (location.x - size.width / 2) / travel
        let y = (size.height / 2 - location.y) / travel
        let length = hypot(x, y)
        guard length > 0.08 else { return .zero }
        let magnitude = (min(length, 1) - 0.08) / 0.92
        return CGPoint(x: x / length * magnitude, y: y / length * magnitude)
    }

    static func direction(location: CGPoint, size: CGSize) -> CGPoint {
        let x = location.x - size.width / 2
        let y = size.height / 2 - location.y
        let neutral = min(size.width, size.height) / 6
        return CGPoint(x: abs(x) <= neutral ? 0 : (x < 0 ? -1 : 1),
                       y: abs(y) <= neutral ? 0 : (y < 0 ? -1 : 1))
    }

    private static func equal(_ lhs: ControllerInputSample, _ rhs: ControllerInputSample) -> Bool {
        lhs.buttons == rhs.buttons && lhs.leftTrigger == rhs.leftTrigger && lhs.rightTrigger == rhs.rightTrigger
            && lhs.leftStickX == rhs.leftStickX && lhs.leftStickY == rhs.leftStickY
            && lhs.rightStickX == rhs.rightStickX && lhs.rightStickY == rhs.rightStickY
    }
}
