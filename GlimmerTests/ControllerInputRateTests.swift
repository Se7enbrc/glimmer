// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  ControllerInputRateTests.swift
//
//  The motion uplink's rate gate (a slower pad's samples all pass, a faster
//  one is held to the host rate) and the raw DualSense report-rate window.
//

import Foundation
import GameController
import Testing
@testable import Glimmer

struct ControllerInputRateTests {

    @MainActor
    @Test func motionOwnershipSendsGyroNullBlocksLateCallbacksAndResumesRequestedSensors() async throws {
        let sampler = ControllerMotion()
        let controller = MotionTestController()
        let profile = controller.testMotion
        let backend = InputRecordingBackend()
        sampler.streamActivated(backend: backend)
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
        defer { sampler.unregister(slot: 0) }
        let caps = sampler.register(slot: 0, controller: controller, inputEnabled: true)
        #expect(caps & UInt16(StreamProtocol.LI_CCAP_ACCEL | StreamProtocol.LI_CCAP_GYRO) != 0)
        sampler.apply(slot: 0, motionType: UInt8(StreamProtocol.LI_MOTION_TYPE_ACCEL), reportRateHz: 100)
        sampler.apply(slot: 0, motionType: UInt8(StreamProtocol.LI_MOTION_TYPE_GYRO), reportRateHz: 100)
        let lateCallback = try #require(profile.valueChangedHandler)
        lateCallback(profile)
        #expect(backend.motions.count == 2)
        #expect(profile.sensorsActive)

        sampler.setInputEnabled(false, slot: 0)
        #expect(backend.motions.last == ControllerMotionSend(num: 0,
            motionType: UInt8(StreamProtocol.LI_MOTION_TYPE_GYRO), x: 0, y: 0, z: 0))
        #expect(profile.valueChangedHandler == nil)
        #expect(!profile.sensorsActive)
        let stopped = backend.motions.count
        lateCallback(profile)
        sampler.apply(slot: 0, motionType: UInt8(StreamProtocol.LI_MOTION_TYPE_GYRO), reportRateHz: 50)
        #expect(backend.motions.count == stopped)
        #expect(profile.valueChangedHandler == nil)

        sampler.setInputEnabled(true, slot: 0)
        #expect(profile.sensorsActive)
        #expect(profile.valueChangedHandler != nil)
        #expect(backend.motions.count == stopped + 2)
        #expect(backend.motions.last?.y != 0)
        sampler.setInputEnabled(false, slot: 0)
        sampler.apply(slot: 0, motionType: UInt8(StreamProtocol.LI_MOTION_TYPE_ACCEL), reportRateHz: 0)
        sampler.apply(slot: 0, motionType: UInt8(StreamProtocol.LI_MOTION_TYPE_GYRO), reportRateHz: 0)
        sampler.setInputEnabled(true, slot: 0)
        #expect(profile.valueChangedHandler == nil)
        #expect(!profile.sensorsActive)
    }

    /// Admitted sample count for a pad reporting every `periodMs` for one second.
    private func admitted(periodMs: Double, rateHz: UInt16, jitterMs: (Int) -> Double = { _ in 0 }) -> Int {
        var gate = MotionRateGate()
        let count = Int(1000 / periodMs)
        return (0..<count).filter { i in
            gate.admit(at: (Double(i) * periodMs + jitterMs(i)) / 1000, rateHz: rateHz)
        }.count
    }

    // MARK: - Motion rate gate

    @Test func slowerPadSendsEverySample() {
        // The DualSense's ~66.7 Hz IMU against Sunshine's 100 Hz ask.
        #expect(admitted(periodMs: 15, rateHz: 100) == 66)
    }

    @Test func jitteredSlowerPadStillSendsEverySample() {
        // A 6 ms late sample followed by an on-time one lands 9 ms apart.
        #expect(admitted(periodMs: 15, rateHz: 100, jitterMs: { $0 % 4 == 1 ? 6 : 0 }) == 66)
    }

    @Test func fasterPadIsHeldToTheHostRate() {
        let sent = admitted(periodMs: 4, rateHz: 100)   // 250 Hz source
        #expect((100...102).contains(sent), "sent \(sent)")
    }

    @Test func idleNeverBanksMoreThanTwoSamples() {
        var gate = MotionRateGate()
        let first = gate.admit(at: 0, rateHz: 100)
        #expect(first)
        let burst = (0..<5).filter { gate.admit(at: 60 + Double($0) * 0.001, rateHz: 100) }.count
        #expect(burst == 2)
    }

    // MARK: - Raw report rate

    @Test func reportRateNeedsAFullSecond() {
        var rate = HIDReportRate()
        for i in 0..<200 { rate.record(at: Double(i) * 0.004) }   // 0.796 s at 250 Hz
        #expect(rate.perSecond == nil)
    }

    @Test func reportRateMatchesTheCadence() throws {
        for (period, expected) in [(0.004, 250.0), (0.015, 66.67)] {
            var rate = HIDReportRate()
            for i in 0...Int(2.5 / period) { rate.record(at: Double(i) * period) }
            let measured = try #require(rate.perSecond)
            #expect(abs(measured - expected) < 0.5, "period \(period): \(measured)")
        }
    }
}

private final class MotionTestController: GCController {
    let testMotion = MotionTestProfile()
    override var motion: GCMotion? { testMotion }
}

private final class MotionTestProfile: GCMotion {
    private var active = false
    private var handler: GCMotionValueChangedHandler?
    override var valueChangedHandler: GCMotionValueChangedHandler? {
        get { handler }
        set { handler = newValue }
    }
    override var hasGravityAndUserAcceleration: Bool { true }
    override var hasRotationRate: Bool { true }
    override var sensorsRequireManualActivation: Bool { true }
    override var sensorsActive: Bool {
        get { active }
        set { active = newValue }
    }
    override var acceleration: GCAcceleration { GCAcceleration(x: 0, y: -1, z: 0) }
    override var rotationRate: GCRotationRate { GCRotationRate(x: 1, y: 2, z: 3) }
}
