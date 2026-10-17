// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GameController
import Synchronization
import Testing
@testable import Glimmer

struct IOSControllerSensorsTests {
    @Test func motionPreservesNativeUnitsAndInvalidatesQueuedCallbacks() throws {
        let native = TestMotion()
        let adapter = IOSControllerMotion(native)
        let samples = Mutex(0)
        adapter.setHandler { _ in samples.withLock { $0 += 1 } }
        adapter.setSensorsActive(true)
        #expect(native.sensorsActive)
        let old = try #require(native.valueChangedHandler)
        old(native)
        #expect(samples.withLock { $0 } == 1)
        let sample = try #require(adapter.read())
        #expect(sample.acceleration == SIMD3<Float>(0.25, -0.5, 1))
        #expect(sample.rotation == SIMD3<Float>(2, 3, -4))
        adapter.setHandler(nil)
        old(native)
        #expect(samples.withLock { $0 } == 1)
        adapter.invalidate()
        adapter.setSensorsActive(true)
        adapter.setHandler { _ in samples.withLock { $0 += 100 } }
        old(native)
        #expect(samples.withLock { $0 } == 1)
        #expect(!native.sensorsActive)
        #expect(native.valueChangedHandler == nil)
        #expect(adapter.read() == nil)
    }

    @Test func motionRestoresPreexistingNativeOwner() throws {
        let native = TestMotion()
        let originalCalls = Mutex(0)
        native.sensorsActive = true
        native.valueChangedHandler = { _ in originalCalls.withLock { $0 += 1 } }
        let adapter = IOSControllerMotion(native)
        adapter.setHandler { _ in Issue.record("An invalidated sensor callback must not run.") }
        adapter.setSensorsActive(false)
        adapter.invalidate()
        #expect(native.sensorsActive)
        let restored = try #require(native.valueChangedHandler)
        restored(native)
        #expect(originalCalls.withLock { $0 } == 1)
    }

    @MainActor
    @Test func batteryPreservesUnknownStateAndLevelForSharedPolicy() {
        let sample = IOSControllerBattery.sample(state: .unknown, level: -1)
        #expect(sample.state == .unknown)
        #expect(sample.level == -1)
        #expect(IOSControllerBattery.capture(GCController.withExtendedGamepad()) == nil)
    }
}

private final class TestMotion: GCMotion {
    private var active = false
    private var handler: GCMotionValueChangedHandler?
    override var sensorsRequireManualActivation: Bool { true }
    override var sensorsActive: Bool {
        get { active }
        set { active = newValue }
    }
    override var valueChangedHandler: GCMotionValueChangedHandler? {
        get { handler }
        set { handler = newValue }
    }
    override var hasGravityAndUserAcceleration: Bool { true }
    override var hasRotationRate: Bool { true }
    override var acceleration: GCAcceleration { GCAcceleration(x: 0.25, y: -0.5, z: 1) }
    override var rotationRate: GCRotationRate { GCRotationRate(x: 2, y: 3, z: -4) }
}
