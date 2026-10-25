// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import UIKit

@MainActor
final class StreamTouchCapture: NSObject, UIGestureRecognizerDelegate {
    struct Actions {
        let move: (CGPoint, TimeInterval) -> Void
        let scroll: (CGPoint, TimeInterval) -> Void
        let click: (Bool, TimeInterval) -> Void
        let endScroll: () -> Void
        let revealControls: () -> Void
    }

    let primaryTap = StreamTapRecognizer()
    let secondaryTap = StreamTapRecognizer()
    let revealTap = StreamTapRecognizer()
    let pointerPan = StreamPanRecognizer()
    let scrollPan = StreamPanRecognizer()
    private let actions: Actions
    private let clock: () -> TimeInterval
    private var enabled = false
    private var mouseEnabled = true
    private weak var view: UIView?

    init(view: UIView, actions: Actions,
         clock: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }) {
        self.view = view
        self.actions = actions
        self.clock = clock
        super.init()
        primaryTap.numberOfTouchesRequired = 1
        secondaryTap.numberOfTouchesRequired = 2
        revealTap.numberOfTouchesRequired = 3
        pointerPan.minimumNumberOfTouches = 1
        pointerPan.maximumNumberOfTouches = 1
        scrollPan.minimumNumberOfTouches = 2
        scrollPan.maximumNumberOfTouches = 2
        for recognizer in recognizers {
            recognizer.delegate = self
            recognizer.allowedTouchTypes = [NSNumber(value: UITouch.TouchType.direct.rawValue)]
            recognizer.addTarget(self, action: #selector(changed(_:)))
            recognizer.isEnabled = false
            view.addGestureRecognizer(recognizer)
        }
        // A multi-finger or moving gesture must resolve before a click reaches the PC.
        primaryTap.require(toFail: secondaryTap)
        primaryTap.require(toFail: revealTap)
        primaryTap.require(toFail: pointerPan)
        primaryTap.require(toFail: scrollPan)
        secondaryTap.require(toFail: revealTap)
        secondaryTap.require(toFail: scrollPan)
        pointerPan.require(toFail: revealTap)
        scrollPan.require(toFail: revealTap)
    }

    isolated deinit {
        for recognizer in recognizers { view?.removeGestureRecognizer(recognizer) }
    }

    var recognizers: [UIGestureRecognizer] { [primaryTap, secondaryTap, revealTap, pointerPan, scrollPan] }

    func setEnabled(_ enabled: Bool, mouseEnabled: Bool = true) {
        guard self.enabled != enabled || self.mouseEnabled != mouseEnabled else { return }
        self.enabled = enabled
        self.mouseEnabled = mouseEnabled
        for recognizer in recognizers {
            recognizer.isEnabled = enabled && (recognizer === revealTap || mouseEnabled)
        }
        if !enabled || !mouseEnabled { actions.endScroll() }
    }

    func gestureRecognizer(_ gestureRecognizer: UIGestureRecognizer, shouldReceive touch: UITouch) -> Bool {
        guard enabled else { return false }
        return Self.acceptsTouch(startingIn: touch.view)
    }

    static func acceptsTouch(startingIn view: UIView?) -> Bool {
        var candidate = view
        while let target = candidate {
            if target is UIControl { return false }
            candidate = target.superview
        }
        return true
    }

    @objc private func changed(_ recognizer: UIGestureRecognizer) {
        guard enabled else { return }
        if let pan = recognizer as? UIPanGestureRecognizer {
            handlePan(scroll: pan === scrollPan, state: pan.state,
                      translation: pan.translation(in: view), capturedAt: timestamp(for: recognizer))
            pan.setTranslation(.zero, in: view)
        } else if recognizer.state == .recognized {
            handleTap(touches: recognizer === revealTap ? 3 : recognizer === secondaryTap ? 2 : 1,
                      capturedAt: timestamp(for: recognizer))
        }
    }

    func timestamp(for recognizer: UIGestureRecognizer) -> TimeInterval {
        if let tap = recognizer as? StreamTapRecognizer { return tap.eventTimestamp ?? clock() }
        if let pan = recognizer as? StreamPanRecognizer { return pan.eventTimestamp ?? clock() }
        return clock()
    }

    func handleTap(touches: Int, capturedAt: TimeInterval) {
        guard enabled else { return }
        if touches == 3 {
            setEnabled(false)
            actions.revealControls()
        } else if mouseEnabled && (touches == 1 || touches == 2) {
            actions.click(touches == 2, capturedAt)
        }
    }

    func handlePan(scroll: Bool, state: UIGestureRecognizer.State, translation: CGPoint,
                   capturedAt: TimeInterval) {
        guard enabled, mouseEnabled else { return }
        if state == .began || state == .changed {
            if scroll { actions.scroll(translation, capturedAt) } else { actions.move(translation, capturedAt) }
        } else if scroll && (state == .ended || state == .cancelled || state == .failed) {
            actions.endScroll()
        }
    }
}
