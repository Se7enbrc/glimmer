// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import UIKit

@MainActor
class TouchGamepadView: UIView {
    private(set) var controls: [TouchElement: UIControl] = [:]
    let menuButton = TouchMenuButton(frame: .zero)
    private(set) var opacity = TouchLayout.defaultOpacity
    private var capture: TouchGamepadCapture?
    private var lastFrames: [TouchElement: CGRect] = [:]
    private var preview = false
    private var menuVisible = true
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

    func setMenuVisible(_ visible: Bool, animated: Bool) {
        guard menuVisible != visible else { return }
        menuVisible = visible
        menuButton.isUserInteractionEnabled = visible
        menuButton.accessibilityElementsHidden = !visible
        if animated {
            UIView.animate(withDuration: 0.2, delay: 0, options: [.beginFromCurrentState, .allowUserInteraction]) {
                self.menuButton.alpha = visible ? 1 : 0
            }
        } else {
            menuButton.layer.removeAllAnimations()
            menuButton.alpha = visible ? 1 : 0
        }
    }

    // Pad visibility follows capture; the menu has its own finite visibility window.
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

    func mouseMode(_ enabled: Bool, bindings: ControllerMouseBindings = ControllerLayoutsModel.shared.mouse) {
        for (element, control) in controls {
            control.accessibilityLabel = element.name
            (control as? TouchAxisControl)?.showMode(nil)
            (control as? TouchTrigger)?.showMode(nil)
        }
        guard enabled else { return }
        for action in ControllerMouseAction.allCases {
            for element in TouchElement.allCases where !element.mouseSources.isDisjoint(with: bindings[action]) {
                controls[element]?.accessibilityLabel = "\(element.name), \(action.title)"
                (controls[element] as? TouchAxisControl)?.showMode(action == .pointer ? "Pointer" : "Scroll")
                (controls[element] as? TouchTrigger)?.showMode(action.title)
            }
        }
    }

    private func inputTracking(_ control: UIControl) -> TouchTracking? {
        if let button = control as? TouchButton { return button.inputTracking }
        if let axis = control as? TouchAxisControl { return axis.inputTracking }
        return (control as? TouchTrigger)?.inputTracking
    }
}
