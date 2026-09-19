//
//  MiniPlayerTests.swift
//
//  The mini player's pure parts: its opening size and corner, the aspect
//  floor, and the default chord's place in the family.
//

import CoreGraphics
import Testing
@testable import Glimmer

struct MiniPlayerTests {

    @Test func opensAQuarterOfTheScreenWideAtTheStreamAspect() {
        let size = StreamWindowGeometry.miniPlayerContentSize(
            aspect: CGSize(width: 3840, height: 2160), visible: CGSize(width: 2056, height: 1300))
        #expect(size == CGSize(width: 514, height: 289))
    }

    @Test func widthIsClampedBetweenTheMinimumAndSixFortyPoints() {
        let narrow = StreamWindowGeometry.miniPlayerContentSize(
            aspect: CGSize(width: 16, height: 9), visible: CGSize(width: 1000, height: 700))
        #expect(narrow.width == StreamWindowGeometry.miniPlayerMinimumContentWidth)
        let wide = StreamWindowGeometry.miniPlayerContentSize(
            aspect: CGSize(width: 16, height: 9), visible: CGSize(width: 5120, height: 2880))
        #expect(wide == CGSize(width: 640, height: 360))
    }

    @Test func minimumSitsOnTheAspectLineAndFallsBackToSixteenNine() {
        let ultrawide = StreamWindowGeometry.miniPlayerMinimumContentSize(aspect: CGSize(width: 21, height: 9))
        #expect(ultrawide.width == 320)
        #expect(abs(ultrawide.height - 320 * 9 / 21) < 0.001)
        let bad = StreamWindowGeometry.miniPlayerMinimumContentSize(aspect: .zero)
        #expect(bad == CGSize(width: 320, height: 180))
    }

    @Test func parksInTheBottomRightOfTheVisibleArea() {
        let visible = CGRect(x: 0, y: 80, width: 2056, height: 1220)
        let origin = StreamWindowGeometry.miniPlayerOrigin(
            frame: CGSize(width: 514, height: 289), visible: visible)
        #expect(origin == CGPoint(x: 2056 - 16 - 514, y: 80 + 16))
    }

    @Test func defaultChordIsTwoKeysAndCollidesWithNothing() {
        let chord = HotkeyChord.defaultMiniPlayer
        #expect(chord.ctrl && !chord.alt && !chord.shift && !chord.cmd)
        #expect(chord.keyChar == "m")
        let others = [HotkeyChord.defaultQuit, .defaultStats, .defaultBookmark, .defaultReleasePointer]
        #expect(!others.contains(chord))
    }
}
