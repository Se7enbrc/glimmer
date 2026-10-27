// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Testing
import GlimmerEngine

struct ControllerMouseMotionTests {
    @Test func pollingKeepsUpWithHighRefreshDisplaysOnEveryPlatform() {
        #expect(InputCore.controllerMousePollInterval <= 1.0 / 120)
    }

    @Test func radialDeadZoneAndResponseAreContinuousAndBounded() {
        #expect(ControllerMouseMotion.velocity(SIMD2(3000, 3000)) == .zero)
        let fine = ControllerMouseMotion.velocity(SIMD2(5000, 0))
        #expect(fine.x > 0 && fine.x < 1 && fine.y == 0)
        let half = ControllerMouseMotion.velocity(SIMD2(16384, 0))
        let full = ControllerMouseMotion.velocity(SIMD2(32767, 0))
        #expect(half.x > fine.x && half.x < full.x / 2)
        #expect(full.x == 1240)
        let diagonal = ControllerMouseMotion.velocity(SIMD2(32767, 32767))
        #expect(abs(diagonal.x * diagonal.x + diagonal.y * diagonal.y - 1240 * 1240) < 0.001)
        #expect(ControllerMouseMotion.velocity(SIMD2(-16384, 0)).x == -half.x)
    }

    @Test func fractionalMotionSurvivesAndIsIndependentOfSamplingRate() {
        func distance(hz: Int, axis: Int16) -> Int {
            var motion = ControllerMouseMotion()
            return (0..<hz).reduce(0) { result, _ in
                result + Int(motion.step(SIMD2(axis, 0), seconds: 1 / Double(hz)).x)
            }
        }
        #expect(distance(hz: 120, axis: 7000) > 0)
        #expect(abs(distance(hz: 60, axis: 16384) - distance(hz: 120, axis: 16384)) <= 1)
        #expect(abs(distance(hz: 120, axis: 16384) - distance(hz: 240, axis: 16384)) <= 1)
        #expect(distance(hz: 120, axis: -7000) == -distance(hz: 120, axis: 7000))
    }

    @Test func stickScrollSendsWholeWheelNotchesOnly() {
        var state = ControllerMouseState(isMouse: true)
        let sent = (0..<120).map { state.sampleMotion((.zero, SIMD2(32767, 32767)), now: Double($0) / 120).scroll }
            .filter { $0 != .zero }
        #expect(!sent.isEmpty)
        #expect(sent.allSatisfy { $0.x % 120 == 0 && $0.y % 120 == 0 && abs(Int($0.x)) <= 120 })
        state.resetIdleMotion((.zero, .zero))
        #expect(state.sampleMotion((.zero, SIMD2(0, 20000)), now: 10).scroll == .zero)
    }

    @Test func samplingDropsResidualOnCenteringAndBoundsStalls() {
        var state = ControllerMouseState(isMouse: true)
        let first = state.sampleMotion((SIMD2(16384, 0), SIMD2(0, 32767)), now: 1)
        #expect(first.pointer.x > 0 && first.pointer.y == 0)
        #expect(first.scroll == .zero)
        state.resetIdleMotion((.zero, .zero))
        #expect(state.sampledAt == nil)
        #expect(state.sampleMotion((SIMD2(32767, 0), .zero), now: 100).pointer.x == 10)
        var motion = ControllerMouseMotion()
        #expect(motion.step(SIMD2(32767, 0), seconds: .infinity) == .zero)
        #expect(motion.step(SIMD2(32767, 0), seconds: 10).x == 62)
    }
}
