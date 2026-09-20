//
//  ScrollQuantizerTests.swift
//
//  Precise scroll slices become whole wheel notches; a classic wheel passes
//  through untouched; direction changes and finished gestures drop the bank.
//

import Testing
@testable import Glimmer

struct ScrollQuantizerTests {

    @Test func classicWheelNotchesPassThrough() {
        var wheel = ScrollQuantizer()
        #expect(wheel.consumeVertical(120) == 120)
        #expect(wheel.consumeVertical(-240) == -240)
        #expect(wheel.consumeVertical(0) == 0)
    }

    @Test func preciseSlicesAreBankedIntoNotches() {
        var wheel = ScrollQuantizer()
        // A MagSpeed spin as the log showed it: ~40-100 units per event.
        #expect(wheel.consumeVertical(65) == 0)
        #expect(wheel.consumeVertical(77) == 120)
        #expect(wheel.consumeVertical(86) == 0)
        #expect(wheel.consumeVertical(95) == 120)
        #expect(wheel.consumeVertical(103) == 120)
    }

    @Test func directionChangeDropsTheBank() {
        var wheel = ScrollQuantizer()
        #expect(wheel.consumeVertical(100) == 0)
        #expect(wheel.consumeVertical(-100) == 0)
        #expect(wheel.consumeVertical(-20) == -120)
    }

    @Test func axesAreIndependentAndResetTogether() {
        var wheel = ScrollQuantizer()
        #expect(wheel.consumeVertical(100) == 0)
        #expect(wheel.consumeHorizontal(100) == 0)
        wheel.reset()
        #expect(wheel.consumeVertical(100) == 0)
        #expect(wheel.consumeHorizontal(30) == 0)
    }
}
