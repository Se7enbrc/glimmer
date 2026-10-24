// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import UIKit

@MainActor
final class TouchTrigger: UISlider {
    let inputTracking: TouchTracking
    private let label = TouchGlyphLabel()

    init(_ element: TouchElement) {
        inputTracking = TouchTracking(element)
        super.init(frame: .zero)
        minimumValue = 0
        maximumValue = 1
        setThumbImage(UIImage(), for: .normal)
        minimumTrackTintColor = .clear
        maximumTrackTintColor = .clear
        label.text = element.title
        label.font = .systemFont(ofSize: 16, weight: .semibold)
        label.textAlignment = .center
        label.isUserInteractionEnabled = false
        addSubview(label)
        accessibilityLabel = element.name
        accessibilityHint = "Press fully, then drag inward to reduce the trigger."
        accessibilityCustomActions = [UIAccessibilityCustomAction(name: "Release") { [weak self] _ in
            self?.adjust(0); return true
        }]
        addAction(UIAction { [weak self] _ in guard let self else { return }; adjust(value) }, for: .valueChanged)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        let colors = TouchAppearance.apply(to: self, pressed: value > 0)
        label.frame = bounds
        label.colors = colors
        accessibilityValue = "\(Int(value * 100))%"
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let accepted = inputTracking.begin(at: touch.location(in: self), size: bounds.size, timestamp: touch.timestamp)
        if accepted { value = 1; setNeedsLayout() }
        return accepted
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let sample = inputTracking.update(at: touch.location(in: self), size: bounds.size, timestamp: touch.timestamp)
        value = Float(sample.x)
        setNeedsLayout()
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        inputTracking.end(at: touch?.timestamp ?? event?.timestamp ?? ProcessInfo.processInfo.systemUptime)
        value = 0
        setNeedsLayout()
    }

    override func cancelTracking(with event: UIEvent?) { endTracking(nil, with: event) }
    override func accessibilityActivate() -> Bool { adjust(value == 0 ? 1 : 0); return true }
    override func accessibilityElementDidLoseFocus() { adjust(0) }
    override func accessibilityIncrement() { adjust(min(1, value + 0.1)) }
    override func accessibilityDecrement() { adjust(max(0, value - 0.1)) }

    private func adjust(_ value: Float) {
        inputTracking.accessible(CGPoint(x: CGFloat(value), y: 0))
        self.value = value
        accessibilityValue = "\(Int(value * 100))%"
        setNeedsLayout()
    }

    func showMode(_ title: String?) { label.text = title ?? inputTracking.element.title }
}
