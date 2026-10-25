// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import UIKit

@MainActor
final class TouchButton: UIButton {
    let inputTracking: TouchTracking
    private let glyph = TouchGlyphLabel()

    init(_ element: TouchElement) {
        inputTracking = TouchTracking(element)
        super.init(frame: .zero)
        setTitle(element.title, for: .normal)
        glyph.font = .systemFont(ofSize: 16, weight: .semibold)
        glyph.isUserInteractionEnabled = false
        glyph.isAccessibilityElement = false
        addSubview(glyph)
        if element == .menu || element == .options {
            setTitle(nil, for: .normal)
            let symbol = element == .menu ? "line.3.horizontal" : "rectangle.on.rectangle"
            setImage(UIImage(systemName: symbol), for: .normal)
        }
        accessibilityLabel = element.name
        accessibilityValue = "Released"
        addTarget(self, action: #selector(primaryAction(_:event:)), for: .primaryActionTriggered)
        accessibilityCustomActions = [
            UIAccessibilityCustomAction(name: "Hold") { [weak self] _ in self?.hold(true); return true },
            UIAccessibilityCustomAction(name: "Release") { [weak self] _ in self?.hold(false); return true }
        ]
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // Keep UIButton's title semantics while the styled label supplies its single visible glyph layer.
    override func titleRect(forContentRect contentRect: CGRect) -> CGRect { .zero }

    override func layoutSubviews() {
        super.layoutSubviews()
        let colors = TouchAppearance.apply(to: self, pressed: isHighlighted)
        glyph.frame = bounds
        if glyph.text != title(for: .normal) { glyph.text = title(for: .normal) }
        glyph.colors = colors
        if inputTracking.element == .menu || inputTracking.element == .options {
            let name = inputTracking.element == .menu ? "line.3.horizontal" : "rectangle.on.rectangle"
            let image = TouchAppearance.symbol(name, colors: colors)
            if self.image(for: .normal) !== image { setImage(image, for: .normal) }
        }
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let accepted = inputTracking.begin(at: touch.location(in: self), size: bounds.size, timestamp: touch.timestamp)
        isHighlighted = accepted
        TouchAppearance.apply(to: self, pressed: accepted)
        return accepted
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        guard bounds.contains(touch.location(in: self)) else {
            inputTracking.end(at: touch.timestamp)
            isHighlighted = false
            TouchAppearance.apply(to: self)
            return false
        }
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        inputTracking.end(at: touch?.timestamp ?? event?.timestamp ?? ProcessInfo.processInfo.systemUptime)
        isHighlighted = false
        accessibilityValue = "Released"
        TouchAppearance.apply(to: self)
    }

    override func cancelTracking(with event: UIEvent?) { endTracking(nil, with: event) }

    override func accessibilityActivate() -> Bool { hold(true); hold(false); return true }
    override func accessibilityElementDidLoseFocus() { hold(false) }

    @objc private func primaryAction(_ sender: UIButton, event: UIEvent?) {
        // Touch tracking already submitted both edges; keyboard activation still needs a complete press.
        guard event?.type != .touches else { return }
        hold(true)
        hold(false)
    }

    private func hold(_ value: Bool) {
        inputTracking.accessible(CGPoint(x: value ? 1 : 0, y: 0))
        accessibilityValue = value ? "Held" : "Released"
        isHighlighted = value
        TouchAppearance.apply(to: self, pressed: value)
    }
}

@MainActor
final class TouchMenuButton: UIButton {
    var showControls: () -> Void = {}

    override init(frame: CGRect) {
        super.init(frame: frame)
        accessibilityLabel = "Show controls"
        addAction(UIAction { [weak self] _ in self?.showControls() }, for: .primaryActionTriggered)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override var isHighlighted: Bool {
        didSet { if isHighlighted != oldValue { setNeedsLayout() } }
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        let colors = TouchAppearance.apply(to: self, pressed: isHighlighted)
        let image = TouchAppearance.symbol("ellipsis", colors: colors)
        if self.image(for: .normal) !== image { setImage(image, for: .normal) }
    }
}
