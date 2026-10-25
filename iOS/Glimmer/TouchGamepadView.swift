// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import UIKit

@MainActor
class TouchGamepadView: UIView {
    private(set) var controls: [TouchElement: UIControl] = [:]
    let menuButton = TouchMenuButton(frame: .zero)
    private(set) var opacity = TouchLayout.defaultOpacity
    private var capture: TouchGamepadCapture?
    private var lastFrames: [TouchElement: CGRect] = [:]
    private var preview = false
    private var transparencyObserver: NSObjectProtocol?

    override init(frame: CGRect) {
        super.init(frame: frame)
        isMultipleTouchEnabled = true
        for element in TouchElement.allCases {
            let control: UIControl
            if element.isTrigger {
                control = TouchTrigger(element)
            } else if element.isStick || element == .dpad {
                control = TouchAxisControl(element)
            } else { control = TouchButton(element) }
            controls[element] = control
            addSubview(control)
        }
        addSubview(menuButton)
        registerForTraitChanges(
            [UITraitAccessibilityContrast.self, UITraitUserInterfaceStyle.self]
        ) { (view: TouchGamepadView, _: UITraitCollection) in
            for control in view.appearanceControls { control.setNeedsLayout() }
        }
        transparencyObserver = NotificationCenter.default.addObserver(
            forName: UIAccessibility.reduceTransparencyStatusDidChangeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                for control in self.appearanceControls { control.setNeedsLayout() }
            }
        }
    }

    isolated deinit {
        if let transparencyObserver { NotificationCenter.default.removeObserver(transparencyObserver) }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    override func hitTest(_ point: CGPoint, with event: UIEvent?) -> UIView? {
        let hit = super.hitTest(point, with: event)
        return hit === self ? nil : hit
    }

    func configure(capture: TouchGamepadCapture?, layout: TouchLayout, area: CGRect, preview: Bool = false) {
        if self.capture !== capture {
            self.capture?.invalidated = nil
            self.capture = capture
            for control in controls.values { inputTracking(control)?.capture = capture }
            capture?.invalidated = { [weak self] in self?.invalidate() }
        }
        let frames = layout.frames(in: area)
        if frames != lastFrames {
            capture?.cancel()
            lastFrames = frames
            for (element, control) in controls {
                if let frame = frames[element] { control.frame = frame }
            }
        }
        let menuFrame = TouchLayout.menuFrame(in: area)
        if menuButton.frame != menuFrame { menuButton.frame = menuFrame }
        applyOpacity(layout.opacity)
        self.preview = preview
        updateVisibility()
    }

    // Only the pad follows the capture; the menu button stays the visible, tappable way back to the controls.
    private func updateVisibility() {
        let active = preview || capture?.enabled == true
        for (element, control) in controls { control.isHidden = !active || lastFrames[element] == nil }
    }

    private var appearanceControls: [UIControl] { Array(controls.values) + [menuButton] }

    private func applyOpacity(_ value: Double) {
        guard opacity != value else { return }
        opacity = value
        UIView.performWithoutAnimation {
            for control in appearanceControls {
                control.setNeedsLayout()
                control.layoutIfNeeded()
            }
        }
    }

    func invalidate() {
        menuButton.cancelTracking(with: nil)
        menuButton.isHighlighted = false
        for control in controls.values {
            inputTracking(control)?.invalidate()
            control.cancelTracking(with: nil)
        }
        updateVisibility()
    }

    func mouseMode(_ enabled: Bool, leftStick: Bool) {
        for (element, control) in controls {
            control.accessibilityLabel = element.name
            (control as? TouchAxisControl)?.showMode(nil)
            (control as? TouchTrigger)?.showMode(nil)
            if element == .leftShoulder || element == .rightShoulder {
                (control as? UIButton)?.setTitle(element.title, for: .normal)
            }
        }
        guard enabled else { return }
        (controls[leftStick ? .leftStick : .rightStick] as? TouchAxisControl)?.showMode("Pointer")
        (controls[leftStick ? .rightStick : .leftStick] as? TouchAxisControl)?.showMode("Scroll")
        let trigger = controls[leftStick ? .leftTrigger : .rightTrigger] as? TouchTrigger
        trigger?.showMode("Click")
        trigger?.accessibilityLabel = "Primary click"
        let shoulder = controls[leftStick ? .leftShoulder : .rightShoulder] as? UIButton
        shoulder?.setTitle("Right", for: .normal)
        shoulder?.accessibilityLabel = "Secondary click"
        controls[.dpad]?.accessibilityLabel = "Scroll"
    }

    private func inputTracking(_ control: UIControl) -> TouchTracking? {
        if let button = control as? TouchButton { return button.inputTracking }
        if let axis = control as? TouchAxisControl { return axis.inputTracking }
        return (control as? TouchTrigger)?.inputTracking
    }
}
