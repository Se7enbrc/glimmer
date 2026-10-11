// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  ControllerHapticsActuationTests.swift
//
//  Rumble coalescing, motor intensity mapping, trigger rumble and light-bar state through the sinks.
//

import GameController
import Testing
@testable import Glimmer

struct ControllerHapticsActuationTests {

    private typealias Motor = (slot: UInt8, locality: GCHapticsLocality, intensity: Float)

    /// A haptics instance with one controller-less pad on slot 0 and every actuation captured.
    private final class Rig: @unchecked Sendable {
        let haptics = ControllerHaptics()
        var motors: [Motor] = []
        var lights: [ControllerHaptics.LightColor] = []

        init(plan: ControllerHaptics.ActuationPlan = .splitHandles) {
            let pad = ControllerHaptics.PadHaptics(controller: nil)
            pad.plan = plan
            pad.triggersSupported = true
            haptics.pads[0] = pad
            haptics.motorSink = { [self] slot, locality, intensity in motors.append((slot, locality, intensity)) }
            haptics.lightSink = { [self] _, color in lights.append(color); return true }
        }
    }

    @Test func splitHandlesMapLowToLeftAndHighToRight() {
        let rig = Rig()
        rig.haptics.apply(slot: 0, lowFreq: 65535, highFreq: 0)
        #expect(rig.motors.map(\.locality) == [.leftHandle, .rightHandle])
        #expect(rig.motors.map(\.intensity) == [1.0, 0.0])
    }

    @Test func mergedPlanDrivesTheStrongerMotor() {
        let rig = Rig(plan: .single(.handles))
        rig.haptics.apply(slot: 0, lowFreq: 0x4000, highFreq: 0x8000)
        #expect(rig.motors.map(\.locality) == [.handles])
        #expect(rig.motors.first?.intensity == Float(0x8000) / 65535.0)
    }

    @Test func zeroRumbleNeverCreatesAMotor() {
        let rig = Rig()
        rig.haptics.apply(slot: 0, lowFreq: 0, highFreq: 0)
        #expect(rig.motors.isEmpty)
    }

    @Test func triggerRumbleDrivesEachTriggerLocality() {
        let rig = Rig()
        rig.haptics.applyTriggers(slot: 0, left: 65535, right: 0x8000)
        #expect(rig.motors.map(\.locality) == [.leftTrigger, .rightTrigger])
        #expect(rig.motors.map(\.intensity) == [1.0, Float(0x8000) / 65535.0])
    }

    @Test func unsupportedTriggersAreIgnored() {
        let rig = Rig()
        rig.haptics.pads[0]?.triggersSupported = false
        rig.haptics.applyTriggers(slot: 0, left: 65535, right: 65535)
        #expect(rig.motors.isEmpty)
    }

    @Test func lightBarColorReachesTheSinkAndLatchesTheBreadcrumb() {
        let rig = Rig()
        rig.haptics.applyLight(slot: 0, red: 1, green: 2, blue: 3)
        #expect(rig.lights.count == 1)
        #expect(rig.lights.first?.red == 1 && rig.lights.first?.blue == 3)
        #expect(rig.haptics.pads[0]?.announcedLightActive == true)
    }

    @Test func aPadWithoutALightDropsTheEvent() {
        let rig = Rig()
        rig.haptics.lightSink = { _, _ in false }
        rig.haptics.applyLight(slot: 0, red: 9, green: 9, blue: 9)
        #expect(rig.haptics.pads[0]?.announcedLightActive == false)
    }

    @Test func burstsCoalesceToTheNewestRumbleAndColor() {
        let rig = Rig()
        rig.haptics.queue.sync { rig.haptics.quiesced = false }
        for low in [UInt16(1000), 2000, 65535] { rig.haptics.setRumble(controllerNumber: 0, lowFreq: low, highFreq: 0) }
        rig.haptics.setLight(controllerNumber: 0, red: 1, green: 1, blue: 1)
        rig.haptics.setLight(controllerNumber: 0, red: 7, green: 8, blue: 9)
        rig.haptics.queue.sync {}
        #expect(rig.motors.map(\.intensity) == [1.0, 0.0])
        #expect(rig.lights.count == 1)
        #expect(rig.lights.first?.green == 8)
    }

    @Test func aQuiescedActuatorDropsEveryEvent() {
        let rig = Rig()
        rig.haptics.setRumble(controllerNumber: 0, lowFreq: 65535, highFreq: 65535)
        rig.haptics.setLight(controllerNumber: 0, red: 1, green: 2, blue: 3)
        rig.haptics.queue.sync {}
        #expect(rig.motors.isEmpty)
        #expect(rig.lights.isEmpty)
    }
}
