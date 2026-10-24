// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import UIKit

@MainActor
final class TouchTracking {
    let element: TouchElement
    weak var capture: TouchGamepadCapture?
    private var contact: TouchGamepadState.Contact?
    private var origin = CGPoint.zero
    private var value = CGPoint.zero
    private lazy var feedback = UIImpactFeedbackGenerator(style: .soft)

    init(_ element: TouchElement) { self.element = element }

    func begin(at location: CGPoint, size: CGSize, timestamp: TimeInterval) -> Bool {
        guard contact == nil, let contact = capture?.begin(element) else { return false }
        self.contact = contact
        origin = location
        update(at: location, size: size, timestamp: timestamp)
        if !element.isStick && !element.isTrigger && element != .dpad {
            feedback.impactOccurred()
        }
        return true
    }

    @discardableResult func update(at location: CGPoint, size: CGSize, timestamp: TimeInterval) -> CGPoint {
        guard let contact else { return .zero }
        let previous = value
        if element.isStick {
            value = TouchGamepadState.stick(location: location, size: size)
        } else if element == .dpad {
            value = TouchGamepadState.direction(location: location, size: size)
        } else if element.isTrigger {
            let inward = element.isLeft ? location.x - origin.x : origin.x - location.x
            value = CGPoint(x: max(0, min(1, 1 - inward / 72)), y: 0)
        } else { value = CGPoint(x: CGRect(origin: .zero, size: size).contains(location) ? 1 : 0, y: 0) }
        capture?.update(contact, value: value, at: timestamp)
        if element == .dpad, value != .zero, value != previous { feedback.impactOccurred() }
        return value
    }

    func end(at timestamp: TimeInterval) {
        if let contact { capture?.end(contact, at: timestamp) }
        contact = nil
        value = .zero
    }

    func invalidate() { contact = nil; value = .zero }

    func accessible(_ value: CGPoint) {
        let time = ProcessInfo.processInfo.systemUptime
        if contact == nil { contact = capture?.begin(element) }
        if let contact { capture?.update(contact, value: value, at: time) }
        self.value = value
        if value == .zero { end(at: time) }
    }
}

@MainActor
enum TouchAppearance {
    struct Colors {
        let fill: UIColor
        let glyph: UIColor
        let border: UIColor
        let thumb: UIColor
    }

    static func colors(style: UIUserInterfaceStyle, contrast: Bool, opaque: Bool, pressed: Bool) -> Colors {
        if style == .dark {
            return Colors(fill: .black.withAlphaComponent(opaque ? 1 : (pressed ? 0.65 : 0.26)),
                          glyph: .white.withAlphaComponent(contrast ? 1 : 0.85),
                          border: .white.withAlphaComponent(contrast ? 1 : 0.38),
                          thumb: .white.withAlphaComponent(0.24))
        }
        let traits = UITraitCollection(userInterfaceStyle: .light)
        let foreground = UIColor.label.resolvedColor(with: traits)
        // Static system fills preserve contrast over video without a live backdrop effect.
        return Colors(fill: UIColor.systemBackground.resolvedColor(with: traits)
                        .withAlphaComponent(opaque ? 1 : (pressed || contrast ? 0.94 : 0.82)),
                      glyph: foreground.withAlphaComponent(contrast ? 1 : 0.90),
                      border: foreground.withAlphaComponent(contrast ? 1 : 0.45),
                      thumb: UIColor.systemFill.resolvedColor(with: traits))
    }

    @discardableResult static func apply(to control: UIControl, pressed: Bool = false) -> Colors {
        let contrast = control.traitCollection.accessibilityContrast == .high
        let dark = control.traitCollection.userInterfaceStyle == .dark
        let colors = colors(style: control.traitCollection.userInterfaceStyle, contrast: contrast,
                            opaque: UIAccessibility.isReduceTransparencyEnabled, pressed: pressed)
        control.backgroundColor = colors.fill
        control.layer.borderColor = colors.border.cgColor
        control.layer.borderWidth = contrast ? 2 : 1
        control.tintColor = colors.glyph
        (control as? UIButton)?.setTitleColor(dark ? .white : colors.glyph, for: .normal)
        control.layer.cornerRadius = min(control.bounds.width, control.bounds.height) / 2
        return colors
    }
}
