// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

@testable import GlimmerEngine
import Foundation
import os
import Testing

struct ControllerFeedbackBoundaryTests {
    @Test(arguments: ["stop", "detach", "focus", "resume"], [false, true])
    func revokedDrainCannotUpdateExistingSiblingMotor(_ cancellation: String, triggers: Bool) {
        let driver = ControllerHaptics()
        let entered = DispatchSemaphore(value: 0)
        let finish = DispatchSemaphore(value: 0)
        let updates = OSAllocatedUnfairLock(initialState: [Float]())
        let left: ControllerFeedbackOutput.Locality = triggers ? .leftTrigger : .leftHandle
        let right: ControllerFeedbackOutput.Locality = triggers ? .rightTrigger : .rightHandle
        let output = ControllerFeedbackOutput(localities: [left, right], makeMotor: { locality, _, _, _ in
            if locality == left {
                entered.signal()
                _ = finish.wait(timeout: .now() + 3)
            }
            return ControllerMotor(updateIntensity: { value in
                if locality == right { updates.withLock { $0.append(value) } }
            }, stop: {})
        })
        driver.register(slot: 0, output: output)
        driver.streamActivated(appActive: true)
        driver.queue.sync {}
        if triggers { driver.setTriggerRumble(controllerNumber: 0, left: 0, right: 65535) } else {
            driver.setRumble(controllerNumber: 0, lowFreq: 0, highFreq: 65535)
        }
        driver.queue.sync {}
        if triggers { driver.setTriggerRumble(controllerNumber: 0, left: 65535, right: 32768) } else {
            driver.setRumble(controllerNumber: 0, lowFreq: 65535, highFreq: 32768)
        }
        #expect(entered.wait(timeout: .now() + 2) == .success)
        switch cancellation {
        case "stop": driver.stopAll(reason: "test")
        case "detach": driver.unregister(slot: 0)
        default:
            driver.setOwnership(false)
            if cancellation == "resume" { driver.setOwnership(true) }
        }
        finish.signal()
        driver.queue.sync {}
        #expect(updates.withLock { $0 } == [0])
        driver.stopAll(reason: "test complete")
        driver.queue.sync {}
    }

    @Test func revokedDrainCannotContinueLightPlayerOrHIDCallsAfterNativeMirrorReturns() {
        let entered = DispatchSemaphore(value: 0)
        let finish = DispatchSemaphore(value: 0)
        let calls = OSAllocatedUnfairLock(initialState: [String]())
        var platform = ControllerHaptics.Platform()
        platform.rumbleHID = { _, _ in calls.withLock { $0.append("HID") } }
        let driver = ControllerHaptics(platform: platform)
        var output = ControllerFeedbackOutput(localities: [], makeMotor: { _, _, _, _ in nil },
            setLight: { _, _, _ in calls.withLock { $0.append("light") } },
            setPlayerIndex: { _ in calls.withLock { $0.append("player") }; return true })
        output.mirrorLight = { _, _, _ in
            entered.signal()
            _ = finish.wait(timeout: .now() + 3)
        }
        driver.register(slot: 0, output: output)
        driver.streamActivated(appActive: true)
        driver.queue.sync {}
        driver.queue.suspend()
        driver.setLight(controllerNumber: 0, red: 1, green: 2, blue: 3)
        driver.setPlayerLEDs(controllerNumber: 0, solid: 1, flashing: 0)
        driver.setRumble(controllerNumber: 1, lowFreq: 65535, highFreq: 0)
        driver.queue.resume()
        #expect(entered.wait(timeout: .now() + 2) == .success)
        driver.setOwnership(false)
        driver.setOwnership(true)
        finish.signal()
        driver.queue.sync {}
        #expect(calls.withLock { $0.isEmpty })
        driver.stopAll(reason: "test complete")
        driver.queue.sync {}
    }

    @Test func ownershipChangeDiscardsUndrainedFeedbackButKeepsFreshCoalescing() {
        let calls = OSAllocatedUnfairLock(initialState: [UInt8]())
        let driver = ControllerHaptics()
        let output = ControllerFeedbackOutput(localities: [], makeMotor: { _, _, _, _ in nil },
            setLight: { red, _, _ in calls.withLock { $0.append(red) } })
        driver.register(slot: 0, output: output)
        driver.streamActivated(appActive: true)
        driver.queue.sync {}
        driver.queue.suspend()
        driver.setLight(controllerNumber: 0, red: 1, green: 0, blue: 0)
        driver.setOwnership(false)
        driver.setOwnership(true)
        driver.queue.resume()
        driver.queue.sync {}
        #expect(calls.withLock { $0.isEmpty })
        driver.queue.suspend()
        driver.setLight(controllerNumber: 0, red: 2, green: 0, blue: 0)
        driver.setLight(controllerNumber: 0, red: 3, green: 0, blue: 0)
        driver.queue.resume()
        driver.queue.sync {}
        #expect(calls.withLock { $0 } == [3])
        driver.stopAll(reason: "test complete")
        driver.queue.sync {}
    }

    @Test(arguments: ["stop", "detach", "focus"])
    func cancelledMotorFactoryDisposesWithoutAdoption(_ cancellation: String) {
        let driver = ControllerHaptics()
        let entered = DispatchSemaphore(value: 0)
        let finish = DispatchSemaphore(value: 0)
        let disposed = OSAllocatedUnfairLock(initialState: 0)
        let output = ControllerFeedbackOutput(localities: [.leftHandle, .rightHandle], makeMotor: { _, _, _, _ in
            entered.signal()
            _ = finish.wait(timeout: .now() + 3)
            return ControllerMotor(updateIntensity: { _ in }, stop: { disposed.withLock { $0 += 1 } })
        })
        driver.register(slot: 0, output: output)
        driver.streamActivated(appActive: true)
        driver.queue.sync {}
        driver.setRumble(controllerNumber: 0, lowFreq: 65535, highFreq: 0)
        #expect(entered.wait(timeout: .now() + 2) == .success)
        let observed = OSAllocatedUnfairLock(initialState: false)
        driver.queue.async {
            observed.withLock { $0 = (driver.pads[0]?.engines.isEmpty ?? true) && disposed.withLock { $0 } == 1 }
        }
        switch cancellation {
        case "stop": driver.stopAll(reason: "test")
        case "detach": driver.unregister(slot: 0)
        default: driver.setOwnership(false)
        }
        finish.signal()
        driver.queue.sync {}
        #expect(observed.withLock { $0 })
        #expect(disposed.withLock { $0 } == 1)
        #expect(driver.queue.sync { driver.pads[0]?.engines.isEmpty ?? true })
    }

    @Test func lateMotorInvalidationCannotDropReplacementChannel() {
        let driver = ControllerHaptics()
        let callbacks = OSAllocatedUnfairLock(initialState: [@Sendable (String) -> Void]())
        let disposed = OSAllocatedUnfairLock(initialState: 0)
        let output = ControllerFeedbackOutput(localities: [.handles], makeMotor: { _, _, _, invalidated in
            callbacks.withLock { $0.append(invalidated) }
            return ControllerMotor(updateIntensity: { _ in }, stop: { disposed.withLock { $0 += 1 } })
        })
        driver.register(slot: 0, output: output)
        driver.streamActivated(appActive: true)
        driver.queue.sync {}
        driver.setRumble(controllerNumber: 0, lowFreq: 1, highFreq: 0)
        driver.queue.sync {}
        let old = callbacks.withLock { $0[0] }
        driver.unregister(slot: 0)
        driver.register(slot: 0, output: output)
        driver.queue.sync {}
        driver.setRumble(controllerNumber: 0, lowFreq: 2, highFreq: 0)
        driver.queue.sync {}
        old("engine reset after detach")
        driver.queue.sync {}
        #expect(driver.queue.sync { driver.pads[0]?.engines.count } == 1)
        #expect(disposed.withLock { $0 } == 1)
        driver.stopAll(reason: "test complete")
        driver.queue.sync {}
        #expect(disposed.withLock { $0 } == 2)
    }

    @Test func capturedMotionCallbackCannotCrossDetachOrOwnershipGeneration() throws {
        let motion = ControllerMotion()
        let backend = InputRecordingBackend()
        let handler = OSAllocatedUnfairLock<(@Sendable (ControllerMotionSample) -> Void)?>(initialState: nil)
        let neutral = ControllerMotionSample(acceleration: .zero, rotation: .zero)
        let capture = ControllerMotionCapture(hasAcceleration: false, hasRotation: true, read: { neutral },
            setHandler: { callback in handler.withLock { $0 = callback } }, setSensorsActive: { _ in })
        _ = motion.register(slot: 0, capture: capture, inputEnabled: true)
        motion.streamActivated(backend: backend)
        motion.setMotionEventState(controllerNumber: 0, motionType: 2, reportRateHz: 100)
        let old = try #require(handler.withLock { $0 })
        old(.init(acceleration: .zero, rotation: SIMD3(1, 2, 3)))
        #expect(backend.motions.count == 1)
        motion.setInputEnabled(false, slot: 0)
        motion.setInputEnabled(true, slot: 0)
        let afterResume = backend.motions.count
        old(.init(acceleration: .zero, rotation: SIMD3(4, 5, 6)))
        #expect(backend.motions.count == afterResume)
        let beforeDetach = try #require(handler.withLock { $0 })
        motion.unregister(slot: 0)
        _ = motion.register(slot: 0, capture: capture, inputEnabled: true)
        motion.setMotionEventState(controllerNumber: 0, motionType: 2, reportRateHz: 100)
        let afterDetach = backend.motions.count
        beforeDetach(.init(acceleration: .zero, rotation: SIMD3(7, 8, 9)))
        #expect(backend.motions.count == afterDetach)
        motion.stopAll(reason: "test complete")
    }
}
