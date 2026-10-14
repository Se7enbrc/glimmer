// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Testing
import UIKit
@testable import Glimmer

@MainActor
struct StreamTouchCaptureTests {
    @Test func delayedEventKeepsOriginalTimestampAcrossFocusChange() {
        var now: TimeInterval = 100
        let capture = StreamTouchCapture(view: UIView(), actions: .init(move: { _, _ in }, scroll: { _, _ in },
            click: { _, _ in }, endScroll: {}, revealControls: {}), clock: { now })
        #expect(capture.timestamp(for: capture.primaryTap) == 100)
        capture.setEnabled(true)
        capture.primaryTap.captureTimestamp(12)
        capture.pointerPan.captureTimestamp(13)
        capture.setEnabled(false)
        now = 200
        capture.setEnabled(true)
        #expect(capture.timestamp(for: capture.primaryTap) == 12)
        #expect(capture.timestamp(for: capture.pointerPan) == 13)
    }

    @Test func revealQuiescesTouchesBeforeOpeningControls() {
        var events: [String] = []
        let capture = StreamTouchCapture(view: UIView(), actions: .init(
            move: { _, _ in events.append("move") }, scroll: { _, _ in events.append("scroll") },
            click: { secondary, _ in events.append(secondary ? "secondary" : "primary") },
            endScroll: { events.append("end") }, revealControls: { events.append("reveal") }))
        capture.setEnabled(true)
        capture.handleTap(touches: 3, capturedAt: 1)
        capture.handleTap(touches: 1, capturedAt: 1)
        capture.handlePan(scroll: false, state: .changed, translation: CGPoint(x: 1, y: 2), capturedAt: 1)
        #expect(events == ["end", "reveal"])
        #expect(capture.recognizers.allSatisfy { !$0.isEnabled })
        capture.setEnabled(true)
        capture.handleTap(touches: 2, capturedAt: 2)
        #expect(events == ["end", "reveal", "secondary"])
    }

    @Test func cancellationEndsScrollWithoutCreatingClicksOrFinalMovement() {
        var moves: [CGPoint] = []
        var scrolls: [CGPoint] = []
        var clicks = 0
        var endings = 0
        let capture = StreamTouchCapture(view: UIView(), actions: .init(
            move: { point, _ in moves.append(point) }, scroll: { point, _ in scrolls.append(point) },
            click: { _, _ in clicks += 1 }, endScroll: { endings += 1 }, revealControls: {}))
        capture.setEnabled(true)
        capture.handlePan(scroll: false, state: .changed, translation: CGPoint(x: 4, y: 5), capturedAt: 1)
        capture.handlePan(scroll: false, state: .cancelled, translation: CGPoint(x: 8, y: 9), capturedAt: 1)
        capture.handlePan(scroll: true, state: .changed, translation: CGPoint(x: 1, y: 2), capturedAt: 1)
        capture.handlePan(scroll: true, state: .cancelled, translation: CGPoint(x: 8, y: 9), capturedAt: 1)
        #expect(moves == [CGPoint(x: 4, y: 5)])
        #expect(scrolls == [CGPoint(x: 1, y: 2)])
        #expect(endings == 1)
        #expect(clicks == 0)
        capture.setEnabled(false)
        capture.setEnabled(false)
        #expect(endings == 2)
    }

    @Test func capturedTimestampAndUnquantizedTranslationReachAdapter() {
        var timestamp: TimeInterval = 0
        var translation = CGPoint.zero
        let capture = StreamTouchCapture(view: UIView(), actions: .init(
            move: { translation = $0; timestamp = $1 }, scroll: { _, _ in },
            click: { _, _ in }, endScroll: {}, revealControls: {}))
        capture.setEnabled(true)
        capture.handlePan(scroll: false, state: .changed, translation: CGPoint(x: 0.25, y: -0.75), capturedAt: 42)
        #expect(translation == CGPoint(x: 0.25, y: -0.75))
        #expect(timestamp == 42)
        #expect(capture.pointerPan.maximumNumberOfTouches == 1)
        #expect(capture.scrollPan.minimumNumberOfTouches == 2)
        #expect(capture.scrollPan.maximumNumberOfTouches == 2)
        #expect(capture.revealTap.numberOfTouchesRequired == 3)
    }
}
