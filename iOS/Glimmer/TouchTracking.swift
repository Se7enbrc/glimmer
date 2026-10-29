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
    struct Colors: Hashable {
        let fill: UIColor
        let glyph: UIColor
        let edge: UIColor
        let border: UIColor
        let thumb: UIColor
    }

    private enum Glyph: Hashable {
        case symbol(String)
        case text(String, UIFont)
    }
    private struct GlyphKey: Hashable {
        let glyph: Glyph
        let foreground: UIColor
        let edge: UIColor
    }
    // Callers use the fixed gamepad glyphs and mouse-mode labels, never video or arbitrary user text.
    private static var glyphs: [GlyphKey: UIImage] = [:]

    static func colors(style: UIUserInterfaceStyle, contrast: Bool, opaque: Bool, pressed: Bool,
                       opacity: Double = TouchLayout.defaultOpacity) -> Colors {
        let dark = style == .dark
        let traits = UITraitCollection(userInterfaceStyle: dark ? .dark : .light)
        let background = UIColor.systemBackground.resolvedColor(with: traits)
        let foreground = UIColor.label.resolvedColor(with: traits)
        let strength = TouchLayout.boundedOpacity(opacity)
        let change = strength - TouchLayout.defaultOpacity
        let resting = strength * (dark ? 0.9 : 1.1)
        let fill = max(contrast ? 0.5 : 0, resting + (pressed ? 0.16 : 0))
        let glyph = (dark ? 0.76 : 0.70) + change * 0.5
        return Colors(fill: background.withAlphaComponent(opaque ? 1 : fill),
                      glyph: foreground.withAlphaComponent(contrast ? 1 : max(pressed ? 0.94 : 0, glyph)),
                      edge: background.withAlphaComponent(contrast ? 1 : pressed ? 0.90 : 0.78),
                      border: foreground.withAlphaComponent(contrast ? 0.65 : (pressed ? 0.35 : 0.20) + change * 0.3),
                      thumb: background.withAlphaComponent(contrast ? 0.35 : strength * 0.5 + (pressed ? 0.08 : 0)))
    }

    @discardableResult static func apply(to control: UIControl, pressed: Bool = false) -> Colors {
        let contrast = control.traitCollection.accessibilityContrast == .high
        let colors = colors(style: control.traitCollection.userInterfaceStyle, contrast: contrast,
                            opaque: UIAccessibility.isReduceTransparencyEnabled, pressed: pressed,
                            opacity: (control.superview as? TouchGamepadView)?.opacity ?? TouchLayout.defaultOpacity)
        control.backgroundColor = colors.fill
        control.layer.borderColor = colors.border.cgColor
        control.layer.borderWidth = contrast ? 2 : 0.75
        control.tintColor = colors.glyph
        (control as? UIButton)?.setTitleColor(colors.glyph, for: .normal)
        control.layer.cornerRadius = min(control.bounds.width, control.bounds.height) / 2
        return colors
    }

    static func symbol(_ name: String, colors: Colors) -> UIImage? {
        image(for: .symbol(name), colors: colors)
    }

    static func text(_ title: String, font: UIFont, colors: Colors) -> UIImage? {
        image(for: .text(title, font), colors: colors)
    }

    private static func image(for glyph: Glyph, colors: Colors) -> UIImage? {
        let key = GlyphKey(glyph: glyph, foreground: colors.glyph, edge: colors.edge)
        if let image = glyphs[key] { return image }
        guard let source = source(for: glyph) else { return nil }
        let bounds = CGRect(origin: .zero, size: CGSize(width: source.size.width + 2, height: source.size.height + 2))
        // Rasterize the whole silhouette once; font-path strokes expose interior seams in some letters.
        let image = UIGraphicsImageRenderer(bounds: bounds).image { _ in
            let edge = source.withTintColor(colors.edge, renderingMode: .alwaysOriginal)
            for offset in [CGPoint(x: -0.6, y: 0), CGPoint(x: 0.6, y: 0),
                           CGPoint(x: 0, y: -0.6), CGPoint(x: 0, y: 0.6)] {
                edge.draw(at: CGPoint(x: 1 + offset.x, y: 1 + offset.y))
            }
            source.withTintColor(colors.glyph, renderingMode: .alwaysOriginal).draw(at: CGPoint(x: 1, y: 1))
        }.withRenderingMode(.alwaysOriginal)
        glyphs[key] = image
        return image
    }

    private static func source(for glyph: Glyph) -> UIImage? {
        switch glyph {
        case .symbol(let name):
            let size: CGFloat = name == "plus" ? 32 : 17
            return UIImage(systemName: name, withConfiguration:
                UIImage.SymbolConfiguration(pointSize: size, weight: .semibold))
        case .text(let title, let font):
            guard !title.isEmpty else { return nil }
            let text = NSAttributedString(string: title, attributes: [.font: font, .foregroundColor: UIColor.white])
            let size = text.size()
            let renderer = UIGraphicsImageRenderer(size: CGSize(width: ceil(size.width), height: ceil(size.height)))
            return renderer.image { _ in
                text.draw(at: .zero)
            }
        }
    }
}

@MainActor
final class TouchGlyphLabel: UILabel {
    var colors: TouchAppearance.Colors? {
        didSet { if colors != oldValue { setNeedsDisplay() } }
    }

    override func drawText(in rect: CGRect) {
        guard let text, let colors, let image = TouchAppearance.text(text, font: font, colors: colors) else { return }
        image.draw(at: CGPoint(x: (bounds.width - image.size.width) / 2, y: (bounds.height - image.size.height) / 2))
    }
}
