// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Testing
import UIKit
@testable import Glimmer

@MainActor
struct StreamMenuTests {
    @Test func hidesAfterTwoSecondsAndHasNoWorkWhileHidden() async {
        let clock = MenuClock()
        let menu = StreamMenuVisibility(voiceOver: false, sleep: clock.sleep)
        #expect(!menu.visible && !menu.hasPendingHide)
        menu.setPlaying(true)
        await clock.waitForSleeps(1)
        #expect(menu.visible)
        await clock.advance(by: .milliseconds(1999))
        #expect(menu.visible)
        await clock.advance(by: .milliseconds(1))
        await menu.waitForPendingHide()
        #expect(!menu.visible && !menu.hasPendingHide)
        menu.setPlaying(true)
        #expect(await clock.durations == [.seconds(2)])
    }

    @Test func revealingRestartsTheDeadlineAndCancelledWorkCannotHideIt() async {
        let clock = MenuClock()
        let menu = StreamMenuVisibility(voiceOver: false, sleep: clock.sleep)
        menu.setPlaying(true)
        await clock.waitForSleeps(1)
        let first = menu.hideTask
        await clock.advance(by: .seconds(1))
        menu.reveal()
        await clock.waitForSleeps(2)
        await clock.advance(by: .seconds(1))
        await first?.value
        #expect(menu.visible && menu.hasPendingHide)
        await clock.advance(by: .seconds(1))
        await menu.waitForPendingHide()
        #expect(!menu.visible && !menu.hasPendingHide)
        menu.setPlaying(false)
        menu.reveal()
        #expect(!menu.visible && !menu.hasPendingHide)
    }

    @Test func voiceOverKeepsTheMenuReachableAndAnnouncesIt() async {
        let clock = MenuClock()
        var announcements: [String] = []
        let menu = StreamMenuVisibility(voiceOver: false, sleep: clock.sleep, announce: { announcements.append($0) })
        menu.setPlaying(true)
        await clock.waitForSleeps(1)
        let first = menu.hideTask
        menu.voiceOverChanged(true)
        await clock.advance(by: .seconds(10))
        await first?.value
        #expect(menu.visible && !menu.hasPendingHide)
        #expect(announcements == ["Stream controls available."])
        menu.voiceOverChanged(false)
        await clock.waitForSleeps(2)
        let pending = menu.hideTask
        menu.setPlaying(false)
        await clock.advance(by: .seconds(10))
        await pending?.value
        #expect(!menu.visible && !menu.hasPendingHide)
    }

    @Test func topRevealAreaExcludesControlsAndLeavesOtherMouseTouchesAlone() {
        let view = UIView(frame: CGRect(x: 0, y: 0, width: 900, height: 400))
        let capture = StreamTouchCapture(view: view, actions: .init(
            move: { _, _ in }, scroll: { _, _ in }, click: { _, _ in }, endScroll: {}, revealControls: {}))
        let top = CGPoint(x: 200, y: 22), below = CGPoint(x: 200, y: 44)
        #expect(capture.acceptsTouch(capture.menuTap, startingIn: view, at: top))
        #expect(capture.acceptsTouch(capture.menuSwipe, startingIn: view, at: top))
        #expect(!capture.acceptsTouch(capture.menuTap, startingIn: view, at: below))
        #expect(!capture.acceptsTouch(capture.menuSwipe, startingIn: UIButton(), at: top))
        #expect(!capture.acceptsTouch(capture.pointerPan, startingIn: view, at: top))
        #expect(capture.acceptsTouch(capture.pointerPan, startingIn: view, at: below))
        #expect(capture.menuSwipe.direction == .down)
        capture.setEnabled(true, mouseEnabled: false)
        #expect(capture.menuTap.isEnabled && capture.menuSwipe.isEnabled && !capture.pointerPan.isEnabled)
    }

    @Test func hiddenGamepadMenuDoesNotInterceptTouchesAndReduceMotionIsImmediate() {
        let view = TouchGamepadView(frame: CGRect(x: 0, y: 0, width: 900, height: 400))
        view.configure(capture: nil, layout: TouchLayout(), area: view.bounds, preview: true)
        let point = view.menuButton.center
        #expect(view.hitTest(point, with: nil) === view.menuButton)
        view.setMenuVisible(false, animated: false)
        #expect(view.hitTest(point, with: nil) == nil)
        #expect(view.menuButton.alpha == 0 && view.menuButton.accessibilityElementsHidden)
        #expect(view.menuButton.layer.animationKeys()?.isEmpty ?? true)
        view.setMenuVisible(true, animated: false)
        #expect(view.hitTest(point, with: nil) === view.menuButton)
        #expect(!view.menuButton.accessibilityElementsHidden)
    }
}

private actor MenuClock {
    private var now: Duration = .zero
    private(set) var durations: [Duration] = []
    private var sleepers: [(Duration, CheckedContinuation<Void, Never>)] = []
    private var observers: [(Int, CheckedContinuation<Void, Never>)] = []

    func sleep(_ duration: Duration) async throws {
        durations.append(duration)
        await withCheckedContinuation { continuation in
            sleepers.append((now + duration, continuation))
            let ready = observers.filter { $0.0 <= durations.count }
            observers.removeAll { $0.0 <= durations.count }
            for (_, observer) in ready { observer.resume() }
        }
    }

    func waitForSleeps(_ count: Int) async {
        if durations.count >= count { return }
        await withCheckedContinuation { observers.append((count, $0)) }
    }

    func advance(by duration: Duration) {
        now += duration
        let ready = sleepers.filter { $0.0 <= now }
        sleepers.removeAll { $0.0 <= now }
        for (_, continuation) in ready { continuation.resume() }
    }
}
