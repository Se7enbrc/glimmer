// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Testing
@testable import GlimmerEngine

struct ControllerMouseMotionTests {
    @Test func pollingKeepsUpWithHighRefreshDisplays() {
        #expect(InputCore.controllerMousePollInterval <= 1.0 / 120)
    }

    @Test func radialDeadZoneAndResponseAreContinuousAndBounded() {
        #expect(ControllerMouseMotion.velocity(x: 3000, y: 3000) == .zero)
        let fine = ControllerMouseMotion.velocity(x: 5000, y: 0)
        #expect(fine.x > 0 && fine.x < 1 && fine.y == 0)
        let half = ControllerMouseMotion.velocity(x: 16384, y: 0)
        let full = ControllerMouseMotion.velocity(x: 32767, y: 0)
        #expect(half.x > fine.x && half.x < full.x / 2)
        #expect(full.x == 1240)
        let diagonal = ControllerMouseMotion.velocity(x: 32767, y: 32767)
        #expect(abs(diagonal.x * diagonal.x + diagonal.y * diagonal.y - 1240 * 1240) < 0.001)
        #expect(ControllerMouseMotion.velocity(x: -16384, y: 0).x == -half.x)
    }

    @Test func fractionalMotionSurvivesAndIsIndependentOfSamplingRate() {
        func distance(hz: Int, axis: Int16) -> Int {
            var motion = ControllerMouseMotion()
            return (0..<hz).reduce(0) { result, _ in
                result + Int(motion.step(x: axis, y: 0, seconds: 1 / Double(hz)).x)
            }
        }
        #expect(distance(hz: 120, axis: 7000) > 0)
        #expect(abs(distance(hz: 60, axis: 16384) - distance(hz: 120, axis: 16384)) <= 1)
        #expect(abs(distance(hz: 120, axis: 16384) - distance(hz: 240, axis: 16384)) <= 1)
        #expect(distance(hz: 120, axis: -7000) == -distance(hz: 120, axis: 7000))
    }

    @Test func samplingUsesSelectedStickAndDropsResidualOnCentering() {
        var state = ControllerMouseState(isMouse: true)
        state.analog.rightStickX = 16384
        state.analog.leftStickY = 32767
        let first = state.sampleMotion(rightPointer: true, now: 1)
        #expect(first.pointer.x > 0 && first.pointer.y == 0)
        #expect(first.scroll.x == 0 && first.scroll.y > 0)
        let next = state.sampleMotion(rightPointer: true, now: 1 + 1.0 / 120)
        #expect(next.pointer.x > 0)
        state.analog = InputCore.neutral
        state.resetIdleMotion(rightPointer: true)
        #expect(state.sampledAt == nil)
        state.analog.leftStickX = 32767
        let resumed = state.sampleMotion(rightPointer: false, now: 100)
        #expect(resumed.pointer.x == 10 && resumed.scroll == .zero)
    }

    @Test func neutralAndInvalidTimeDiscardResidualAndStallsAreBounded() {
        var motion = ControllerMouseMotion()
        _ = motion.step(x: 7000, y: 0, seconds: 0.05)
        #expect(motion.step(x: 0, y: 0, seconds: 0.01) == .zero)
        var fresh = ControllerMouseMotion()
        #expect(motion.step(x: 7000, y: 0, seconds: 0.01) == fresh.step(x: 7000, y: 0, seconds: 0.01))
        #expect(motion.step(x: 32767, y: 0, seconds: .infinity) == .zero)
        #expect(motion.step(x: 32767, y: 0, seconds: -1) == .zero)
        #expect(motion.step(x: 32767, y: 0, seconds: 10).x == 62)
    }
}
