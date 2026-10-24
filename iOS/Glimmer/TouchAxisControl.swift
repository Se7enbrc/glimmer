// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import UIKit

@MainActor
final class TouchAxisControl: UIControl {
    let inputTracking: TouchTracking
    private let thumb = UIView()
    private let symbol = UIImageView(image: UIImage(systemName: "plus"))
    private let cross = CAShapeLayer()
    private let modeLabel = TouchGlyphLabel()
    private var value = CGPoint.zero

    init(_ element: TouchElement) {
        inputTracking = TouchTracking(element)
        super.init(frame: .zero)
        isAccessibilityElement = true
        accessibilityLabel = element.name
        accessibilityValue = "Centered"
        accessibilityTraits = [.adjustable]
        thumb.isUserInteractionEnabled = false
        symbol.isUserInteractionEnabled = false
        symbol.contentMode = .scaleAspectFit
        addSubview(element.isStick ? thumb : symbol)
        modeLabel.font = .systemFont(ofSize: 13, weight: .medium)
        modeLabel.textAlignment = .center
        modeLabel.isUserInteractionEnabled = false
        addSubview(modeLabel)
        if element == .dpad {
            cross.actions = ["path": NSNull(), "fillColor": NSNull(), "strokeColor": NSNull(),
                             "lineWidth": NSNull(), "bounds": NSNull(), "position": NSNull()]
            layer.insertSublayer(cross, at: 0)
        }
        let actions: [(String, CGPoint)] = [("Up", CGPoint(x: 0, y: 1)), ("Down", CGPoint(x: 0, y: -1)),
            ("Left", CGPoint(x: -1, y: 0)), ("Right", CGPoint(x: 1, y: 0)), ("Center", .zero)]
        accessibilityCustomActions = actions.map { name, value in
            UIAccessibilityCustomAction(name: name) { [weak self] _ in
                self?.inputTracking.accessible(value); self?.display(value); return true
            }
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func layoutSubviews() {
        super.layoutSubviews()
        let colors = TouchAppearance.apply(to: self, pressed: value != .zero)
        let diameter = bounds.width * 0.44
        thumb.bounds = CGRect(x: 0, y: 0, width: diameter, height: diameter)
        thumb.center = CGPoint(x: bounds.midX + value.x * bounds.width * 0.3,
                               y: bounds.midY - value.y * bounds.height * 0.3)
        thumb.backgroundColor = colors.thumb
        thumb.layer.cornerRadius = diameter / 2
        thumb.layer.borderWidth = layer.borderWidth
        thumb.layer.borderColor = colors.border.cgColor
        symbol.frame = bounds.insetBy(dx: 20, dy: 20)
        if inputTracking.element == .dpad {
            let image = TouchAppearance.symbol("plus", colors: colors)
            if symbol.image !== image { symbol.image = image }
        }
        modeLabel.frame = CGRect(x: 0, y: bounds.midY - 10, width: bounds.width, height: 20)
        modeLabel.colors = colors
        if inputTracking.element == .dpad {
            if cross.frame != bounds {
                cross.frame = bounds
                let path = UIBezierPath(roundedRect: CGRect(x: bounds.width / 3, y: 0,
                    width: bounds.width / 3, height: bounds.height), cornerRadius: 12)
                let horizontal = UIBezierPath(roundedRect: CGRect(x: 0, y: bounds.height / 3,
                    width: bounds.width, height: bounds.height / 3), cornerRadius: 12)
                cross.path = path.cgPath.union(horizontal.cgPath)
            }
            cross.fillColor = backgroundColor?.cgColor
            cross.strokeColor = layer.borderColor
            cross.lineWidth = layer.borderWidth
            backgroundColor = .clear
            layer.borderWidth = 0
        }
    }

    override func point(inside point: CGPoint, with event: UIEvent?) -> Bool {
        guard inputTracking.element == .dpad else { return super.point(inside: point, with: event) }
        return bounds.contains(point) && (abs(point.x - bounds.midX) <= bounds.width / 6
            || abs(point.y - bounds.midY) <= bounds.height / 6)
    }

    override func beginTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        let accepted = inputTracking.begin(at: touch.location(in: self), size: bounds.size, timestamp: touch.timestamp)
        if accepted {
            display(inputTracking.update(at: touch.location(in: self), size: bounds.size, timestamp: touch.timestamp))
        }
        return accepted
    }

    override func continueTracking(_ touch: UITouch, with event: UIEvent?) -> Bool {
        display(inputTracking.update(at: touch.location(in: self), size: bounds.size, timestamp: touch.timestamp))
        return true
    }

    override func endTracking(_ touch: UITouch?, with event: UIEvent?) {
        inputTracking.end(at: touch?.timestamp ?? event?.timestamp ?? ProcessInfo.processInfo.systemUptime)
        display(.zero)
    }

    override func cancelTracking(with event: UIEvent?) { endTracking(nil, with: event) }
    override func accessibilityActivate() -> Bool { inputTracking.accessible(.zero); display(.zero); return true }
    override func accessibilityElementDidLoseFocus() { inputTracking.accessible(.zero); display(.zero) }
    override func accessibilityIncrement() {
        inputTracking.accessible(CGPoint(x: 0, y: 1)); display(CGPoint(x: 0, y: 1))
    }
    override func accessibilityDecrement() {
        inputTracking.accessible(CGPoint(x: 0, y: -1)); display(CGPoint(x: 0, y: -1))
    }

    func display(_ value: CGPoint) {
        guard self.value != value else { return }
        self.value = value
        accessibilityValue = value == .zero ? "Centered" : "\(Int(value.x * 100)), \(Int(value.y * 100))"
        setNeedsLayout()
    }

    func showMode(_ title: String?) {
        modeLabel.text = title
        accessibilityLabel = title ?? inputTracking.element.name
    }
}
