// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import Testing

struct ControllerMappingTests {
    private func plan(_ bindings: [ControllerLayoutBinding], extras: [String] = []) throws -> ControllerMappingPlan {
        try ControllerMappingPlan(layout: .init(bindings: bindings),
                                  available: Set(bindings.map(\.source)), extras: extras)
    }

    @Test(arguments: ControllerMappedButton.allCases, ControllerMappedButton.allCases)
    func everyButtonCanReplaceEveryButton(source: ControllerMappedButton, target: ControllerMappedButton) throws {
        var mapping = try plan([.init(.button(source), .button(target))])
        let result1 = mapping.apply(.init(buttons: source.rawValue)).buttons == target.rawValue
        #expect(result1)
        let result2 = mapping.apply(.init()).buttons == 0
        #expect(result2)
    }

    @Test func swapsReadOriginalInputsAndNeverCascade() throws {
        var mapping = try plan([.init(.button(.a), .button(.b)), .init(.button(.b), .button(.a))])
        let result3 = mapping.apply(.init(buttons: ControllerMappedButton.a.rawValue)).buttons == ControllerMappedButton.b.rawValue
        #expect(result3)
    }

    @Test func duplicateDestinationsRemainHeldUntilEverySourceReleases() throws {
        var mapping = try plan([.init(.button(.a), .button(.a)), .init(.extra("back.right"), .button(.a))],
                               extras: ["back.right"])
        var sample = ControllerMappingSample(buttons: ControllerMappedButton.a.rawValue)
        sample.setExtra(0, pressed: true)
        let result4 = mapping.apply(sample).buttons == ControllerMappedButton.a.rawValue
        #expect(result4)
        sample.buttons = 0
        let result5 = mapping.apply(sample).buttons == ControllerMappedButton.a.rawValue
        #expect(result5)
        sample.setExtra(0, pressed: false)
        let result6 = mapping.apply(sample).buttons == 0
        #expect(result6)
    }

    @Test func triggerConversionUsesHysteresisWithoutLosingAnalogTravel() throws {
        var digital = try plan([.init(.trigger(.left), .button(.a))])
        var analog = try plan([.init(.trigger(.left), .trigger(.right))])
        for (value, pressed) in [(127, false), (128, true), (120, true), (115, false), (127, false)] {
            var sample = ControllerMappingSample()
            sample.analog[0] = Int32(value)
            let result7 = (digital.apply(sample).buttons != 0) == pressed
            #expect(result7)
            let result8 = analog.apply(sample).analog[1] == value
            #expect(result8)
        }
    }

    @Test func oppositeDirectionsCancelAndAxisInversionSaturates() throws {
        var digital = try plan([.init(.button(.left), .direction(.leftX, positive: false)),
                                .init(.button(.right), .direction(.leftX, positive: true))])
        let left = ControllerMappedButton.left.rawValue, right = ControllerMappedButton.right.rawValue
        let result9 = digital.apply(.init(buttons: left | right)).analog[2] == 0
        #expect(result9)
        let result10 = digital.apply(.init(buttons: left)).analog[2] == -32767
        #expect(result10)
        var invert = try plan([.init(.axis(.leftX), .axis(.rightY, inverted: true))])
        var sample = ControllerMappingSample()
        sample.analog[2] = -32768
        let result11 = invert.apply(sample).analog[5] == 32767
        #expect(result11)
    }

    @Test func unavailableSourcesAreNotReboundByTheirArrayPosition() throws {
        let layout = ControllerLayout(bindings: [.init(.extra("left.back"), .button(.a))])
        var mapping = try ControllerMappingPlan(layout: layout, available: [.extra("right.back")], extras: ["right.back"])
        var sample = ControllerMappingSample()
        sample.setExtra(0, pressed: true)
        let result12 = mapping.apply(sample).buttons == 0
        #expect(result12)
    }

    @Test func duplicateSourcesAndConflictingFullAxesAreRejected() {
        let duplicate = ControllerLayout(bindings: [.init(.button(.a), .button(.a)), .init(.button(.a), .disabled)])
        #expect(throws: ControllerLayoutError.invalidBindings) { try duplicate.validate() }
        let conflict = ControllerLayout(bindings: [.init(.axis(.leftX), .axis(.leftX, inverted: false)),
                                                   .init(.direction(.leftX, positive: true), .button(.a))])
        #expect(throws: ControllerLayoutError.invalidBindings) { try conflict.validate() }
    }
}
