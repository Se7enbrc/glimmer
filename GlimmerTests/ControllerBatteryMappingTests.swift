//
//  ControllerBatteryMappingTests.swift
//
//  Battery registration, haptic sharpness per locality, and the generic
//  HID pad's type, advertised buttons and trigger kind derived from its mapping.
//

import GameController
import Testing
@testable import Glimmer

@MainActor
struct ControllerBatteryMappingTests {

    @Test func padWithoutABatteryAdvertisesNoBatteryAndReportsNone() throws {
        let forwarder = InputForwarder()
        defer { forwarder.detach() }
        let controller = GCController.withExtendedGamepad()
        #expect(ControllerBattery.shared.register(slot: 14, controller: controller) == 0)
        #expect(forwarder.currentControllerBattery() == nil)
    }

    @Test func sharpnessSeparatesTheHeavyThumpFromTheCrispBuzz() {
        #expect(ControllerHaptics.sharpness(for: .leftHandle) == 0.25)
        #expect(ControllerHaptics.sharpness(for: .rightHandle) == 0.75)
        #expect(ControllerHaptics.sharpness(for: .leftTrigger) == 0.75)
        #expect(ControllerHaptics.sharpness(for: .rightTrigger) == 0.75)
        #expect(ControllerHaptics.sharpness(for: .handles) == 0.5)
        #expect(ControllerHaptics.sharpness(for: .all) == 0.5)
    }

    @Test func mappingNameDecidesTheAdvertisedControllerType() {
        let cases: [(String, Int32)] = [
            ("Xbox Wireless Controller", StreamProtocol.LI_CTYPE_XBOX),
            ("DualSense Edge", StreamProtocol.LI_CTYPE_PS),
            ("PlayStation Classic", StreamProtocol.LI_CTYPE_PS),
            ("Nintendo Switch Pro", StreamProtocol.LI_CTYPE_NINTENDO),
            ("Joy-Con (L)", StreamProtocol.LI_CTYPE_NINTENDO),
            ("8BitDo Ultimate", StreamProtocol.LI_CTYPE_UNKNOWN)
        ]
        for (name, type) in cases {
            #expect(HIDGamepadMapping(name: name, bindings: [:]).controllerType == UInt8(type), "\(name)")
        }
    }

    @Test func advertisedButtonsFollowTheBindingsAndTriggerKind() {
        let mapping = HIDGamepadMapping(name: "Test", bindings: [
            "a": .button(0), "dpup": .hat(0, mask: 1), "guide": .button(2),
            "lefttrigger": .axis(4, half: 0, inverted: false), "righttrigger": .button(5), "leftx": .axis(0, half: 0, inverted: false)
        ])
        let expected = StreamProtocol.A_FLAG | StreamProtocol.UP_FLAG | StreamProtocol.SPECIAL_FLAG
        #expect(mapping.supportedButtons == UInt32(bitPattern: expected))
        #expect(mapping.hasAnalogTriggers)
        let digital = HIDGamepadMapping(name: "Test", bindings: ["lefttrigger": .button(0), "righttrigger": .button(1)])
        #expect(!digital.hasAnalogTriggers)
        #expect(digital.supportedButtons == 0)
    }

    @Test func axisRangeCollapsesToTheRawValueUntilItHasSpan() {
        var range = HIDGamepadElement.AxisRange(minimum: 100, maximum: 100)
        #expect(range.scale(100) == 100)
        #expect(range.scale(200) == 32767)
        #expect(range.scale(150) == 0)
    }
}
