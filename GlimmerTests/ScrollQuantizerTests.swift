//
//  ScrollQuantizerTests.swift
//
//  Precise scroll slices become whole wheel notches; a mouse wheel passes
//  through untouched; direction changes and finished gestures drop the bank.
//

import Testing
@testable import Glimmer

struct ScrollQuantizerTests {

    @Test func wheelUnitsPassThroughUnbanked() {
        var wheel = ScrollQuantizer()
        // Accelerated wheel events from a trace: fractions of a notch, then more.
        #expect(wheel.consumeVertical(12, precise: false) == 12)
        #expect(wheel.consumeVertical(103, precise: false) == 103)
        #expect(wheel.consumeVertical(393, precise: false) == 393)
        #expect(wheel.consumeVertical(-240, precise: false) == -240)
        #expect(wheel.consumeHorizontal(40, precise: false) == 40)
    }

    @Test func preciseSlicesAreBankedIntoNotches() {
        var wheel = ScrollQuantizer()
        // A trackpad swipe: ~40-100 units per event.
        #expect(wheel.consumeVertical(65, precise: true) == 0)
        #expect(wheel.consumeVertical(77, precise: true) == 120)
        #expect(wheel.consumeVertical(86, precise: true) == 0)
        #expect(wheel.consumeVertical(95, precise: true) == 120)
        #expect(wheel.consumeVertical(103, precise: true) == 120)
    }

    @Test func directionChangeDropsTheBank() {
        var wheel = ScrollQuantizer()
        #expect(wheel.consumeVertical(100, precise: true) == 0)
        #expect(wheel.consumeVertical(-100, precise: true) == 0)
        #expect(wheel.consumeVertical(-20, precise: true) == -120)
    }

    @Test func axesAreIndependentAndResetTogether() {
        var wheel = ScrollQuantizer()
        #expect(wheel.consumeVertical(100, precise: true) == 0)
        #expect(wheel.consumeHorizontal(100, precise: true) == 0)
        wheel.reset()
        #expect(wheel.consumeVertical(100, precise: true) == 0)
        #expect(wheel.consumeHorizontal(30, precise: true) == 0)
    }
}
