import Testing
@testable import Glimmer

struct HIDGamepadTests {
    @Test func ultimate2CMapping() throws {
        let mapping = try #require(GameControllerDB.lookup(vendor: 0x2DC8, product: 0x301B, version: 1))
        #expect(mapping.name == "8BitDo Ultimate 2C")
        let expected = ["a": "b0", "b": "b1", "x": "b3", "y": "b4", "back": "b10", "start": "b11",
                        "guide": "b12", "leftshoulder": "b6", "rightshoulder": "b7", "leftstick": "b13",
                        "rightstick": "b14", "paddle1": "b5", "paddle2": "b2", "lefttrigger": "a5",
                        "righttrigger": "a4", "leftx": "a0", "lefty": "a1", "rightx": "a2", "righty": "a3",
                        "dpup": "h0.1", "dpright": "h0.2", "dpdown": "h0.4", "dpleft": "h0.8"]
        for (output, input) in expected { #expect(mapping.bindings[output] == HIDGamepadMapping.Input(input)) }
        #expect(mapping.bindings.count == expected.count)
        #expect(mapping.hasAnalogTriggers)
        #expect(mapping.supportedButtons & UInt32(StreamProtocol.PADDLE2_FLAG) != 0)
    }

    @Test func guidLookupIgnoresBusCRCAndFallsBackOnVersion() throws {
        let old = try #require(HIDGamepadMapping(line: "03000000c82d00001b30000001000000,Old,a:b0,"))
        let new = try #require(HIDGamepadMapping(line: "03000000c82d00001b30000002000000,New,a:b1,"))
        #expect(GameControllerDB.lookup(guid: "0500abcdc82d00001b30000002000000", entries: [old, new])?.name == "New")
        #expect(GameControllerDB.lookup(guid: "0500ffffc82d00001b30000099000000", entries: [old, new])?.name == "Old")
        #expect(GameControllerDB.lookup(guid: "05000000c82d00009999000001000000", entries: [old]) == nil)
        #expect(GameControllerDB.identity("bad") == nil)
        #expect(GameControllerDB.identity(String(repeating: "z", count: 32)) == nil)
    }

    /// The DB keys USB and Bluetooth layouts separately (the DualSense differs per
    /// link), so a Bluetooth pad must get the Bluetooth entry when one exists.
    @Test func lookupPrefersTheMatchingBus() throws {
        let usb = try #require(HIDGamepadMapping(line: "030000004c050000e60c000000010000,USB,a:b1,"))
        let bluetooth = try #require(HIDGamepadMapping(line: "050000004c050000e60c000000010000,BT,a:b2,"))
        #expect(GameControllerDB.lookup(vendor: 0x054C, product: 0x0CE6, version: 1, bus: 0x05,
                                        entries: [usb, bluetooth])?.name == "BT")
        #expect(GameControllerDB.lookup(vendor: 0x054C, product: 0x0CE6, version: 1, bus: 0x03,
                                        entries: [usb, bluetooth])?.name == "USB")
        #expect(GameControllerDB.lookup(vendor: 0x054C, product: 0x0CE6, version: 7, bus: 0x05,
                                        entries: [usb])?.name == "USB")
        #expect(GameControllerDB.bus(forTransport: "Bluetooth Low Energy") == 0x05)
        #expect(GameControllerDB.bus(forTransport: "USB") == 0x03)
    }

    @Test func triggerSemantics() throws {
        let inputs: [(String, Int16, UInt8)] = [
            ("a0", -32768, 0), ("a0", 32767, 255), ("a0", 0, 127),
            ("+a0", 0, 0), ("+a0", 32767, 255), ("+a0", -100, 0),
            ("-a0", 0, 0), ("-a0", -32768, 255), ("-a0", 100, 0),
            ("a0~", -32768, 255), ("a0~", 32767, 0),
            ("+a0~", 0, 255), ("+a0~", 32767, 0),
            ("-a0~", 0, 255), ("-a0~", -32768, 0)
        ]
        for (token, value, expected) in inputs {
            let input = try #require(HIDGamepadMapping.Input(token))
            let mapping = HIDGamepadMapping(name: "Test", bindings: ["lefttrigger": input])
            #expect(mapping.translate(.init(axes: [value])).analog.leftTrigger == expected)
        }
        let mapping = HIDGamepadMapping(name: "Test", bindings: ["lefttrigger": .button(0)])
        #expect(mapping.translate(.init(buttons: [true])).analog.leftTrigger == 255)
        #expect(mapping.translate(.init(buttons: [false])).analog.leftTrigger == 0)
        #expect(!mapping.hasAnalogTriggers)
    }

    @Test func buttonsHatsAndAxisThresholds() {
        let mapping = HIDGamepadMapping(name: "Test", bindings: [
            "dpup": .axis(0, half: -1, inverted: false), "a": .hat(0, mask: 3), "b": .button(0)
        ])
        #expect(mapping.translate(.init(axes: [-16384])).buttons == 0)
        #expect(mapping.translate(.init(axes: [-16385])).buttons == StreamProtocol.UP_FLAG)
        #expect(mapping.translate(.init(axes: [32767])).buttons == 0)
        #expect(mapping.translate(.init(hats: [1])).buttons == 0)
        #expect(mapping.translate(.init(buttons: [true], hats: [3])).buttons == StreamProtocol.A_FLAG | StreamProtocol.B_FLAG)
        let expected: [UInt8] = [1, 3, 2, 6, 4, 12, 8, 9]
        for index in 0..<8 {
            #expect(HIDGamepadElement.hat(value: index + 1, minimum: 1, maximum: 8) == expected[index])
        }
        #expect(HIDGamepadElement.hat(value: 0, minimum: 1, maximum: 8) == 0)
        #expect(HIDGamepadElement.hat(value: 8, minimum: 0, maximum: 7) == 0)
        #expect(HIDGamepadElement.hat(value: 2, minimum: 0, maximum: 3) == 4)
        #expect(HIDGamepadElement.hat(value: 2, minimum: 0, maximum: 15) == 0)
    }

    @Test func elementOrderAndClassification() {
        let elements: [HIDGamepadElement] = [
            .init(cookie: 1, page: 12, usage: 5, kind: .button),
            .init(cookie: 2, page: 9, usage: 1, kind: .button),
            .init(cookie: 3, page: 9, usage: 5, kind: .button),
            .init(cookie: 1, page: 12, usage: 5, kind: .button)
        ]
        #expect(HIDGamepadElement.ordered(elements, kind: .button).map(\.cookie) == [2, 1, 3])
        #expect(HIDGamepadElement.classify(page: 1, usage: 0x38) == .axis)
        #expect(HIDGamepadElement.classify(page: 2, usage: 0xC5) == .axis)
        #expect(HIDGamepadElement.classify(page: 1, usage: 0x39) == .hat)
        #expect(HIDGamepadElement.classify(page: 6, usage: 0x20) == .battery)
        #expect(HIDGamepadElement.classify(page: 7, usage: 0x30) == nil)
        var range = HIDGamepadElement.AxisRange(minimum: 0, maximum: 255)
        #expect(range.scale(0) == -32768)
        #expect(range.scale(255) == 32767)
        #expect(range.scale(511) == 32767)
        #expect(range.maximum == 511)
        #expect(range.scale(-10) == -32768)
        #expect(range.minimum == -10)
    }

    @Test func heuristicUsesUsagesRatherThanAxisPositions() {
        var elements = (0..<12).map {
            HIDGamepadElement(cookie: UInt32($0), page: 9, usage: UInt32($0 + 1), kind: .button)
        }
        elements += [0x35, 0x31, 0x34, 0x30, 0x33, 0x32].enumerated().map {
            .init(cookie: UInt32(20 + $0.offset), page: 1, usage: UInt32($0.element), kind: .axis)
        }
        elements.append(.init(cookie: 40, page: 1, usage: 0x39, kind: .hat))
        let mapping = HIDGamepadMapping.heuristic(elements: elements)
        #expect(mapping.isHeuristic)
        #expect(mapping.bindings["righty"] == .axis(5, half: 0, inverted: false))
        #expect(mapping.bindings["lefttrigger"] == .axis(3, half: 0, inverted: false))
        #expect(mapping.bindings["righttrigger"] == .axis(4, half: 0, inverted: false))
        #expect(mapping.bindings["back"] == .button(8))
        #expect(mapping.bindings["dpdown"] == .hat(0, mask: 4))
        elements.append(.init(cookie: 41, page: 2, usage: 0xC5, kind: .axis))
        #expect(HIDGamepadMapping.heuristic(elements: elements).bindings["lefttrigger"] == .axis(6, half: 0, inverted: false))
        #expect(HIDGamepadMapping.heuristic(elements: []).bindings.isEmpty)
    }

    @Test func snapshotTranslationAndInversion() throws {
        let mapping = try #require(GameControllerDB.lookup(vendor: 0x2DC8, product: 0x301B, version: 1))
        var buttons = Array(repeating: false, count: 15)
        buttons[3] = true
        buttons[5] = true
        let state = mapping.translate(.init(axes: [-32768, -32768, 32767, 32767, -32768, 32767],
                                            buttons: buttons, hats: [3]))
        #expect(state.buttons == StreamProtocol.X_FLAG | StreamProtocol.PADDLE1_FLAG
                | StreamProtocol.UP_FLAG | StreamProtocol.RIGHT_FLAG)
        #expect(state.analog.leftTrigger == 255)
        #expect(state.analog.rightTrigger == 0)
        #expect(state.analog.leftStickX == -32768)
        #expect(state.analog.leftStickY == 32767)
        #expect(state.analog.rightStickX == 32767)
        #expect(state.analog.rightStickY == -32767)
        let inverted = HIDGamepadMapping(name: "Test", bindings: ["leftx": .axis(0, half: 0, inverted: true)])
        #expect(inverted.translate(.init(axes: [-32768])).analog.leftStickX == 32767)
        #expect(inverted.translate(.init(axes: [32767])).analog.leftStickX == -32768)
    }

    @Test func splitStickOutputsAndMalformedInputs() throws {
        let mapping = try #require(HIDGamepadMapping(line:
            "03000000c82d00001b30000001000000,Test,+leftx:h0.2,-leftx:h0.8,platform:Mac OS X,"))
        #expect(mapping.translate(.init(hats: [2])).analog.leftStickX == 32767)
        #expect(mapping.translate(.init(hats: [8])).analog.leftStickX == -32768)
        #expect(mapping.translate(.init(hats: [0])).analog.leftStickX == 0)
        for token in ["", "a-1", "b-2", "h0", "h0.0", "h0.16", "q1", "a1junk", "+b1"] {
            #expect(HIDGamepadMapping.Input(token) == nil)
        }
    }

    @Test func chordMasks() {
        let mask = StreamProtocol.PLAY_FLAG | StreamProtocol.BACK_FLAG | StreamProtocol.LB_FLAG | StreamProtocol.RB_FLAG
        let held = heldControllerButtons(buttons: mask, leftTrigger: 127, rightTrigger: 128)
        #expect(InputForwarder.chordSatisfied(.startSelectL1R1, custom: [], held: held))
        #expect(!held.contains(.l2))
        #expect(held.contains(.r2))
        #expect(!InputForwarder.chordSatisfied(.l1r1l2r2, custom: [], held: held))
        #expect(!InputForwarder.chordSatisfied(.custom, custom: [], held: held))
        #expect(!InputForwarder.chordSatisfied(.none, custom: [], held: held))
    }
}
