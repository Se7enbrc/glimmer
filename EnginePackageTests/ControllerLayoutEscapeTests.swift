// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import Testing

struct ControllerLayoutEscapeTests {
    private let available = Set(ControllerMappedButton.allCases.map { ControllerLayoutSource.button($0) })
    private let menu = ControllerMappedButton.menu.rawValue
    private let options = ControllerMappedButton.options.rawValue

    private func gesture() throws -> ControllerEscapeGesture {
        try .init(chord: .init(sources: ControllerLayoutShortcuts.escape(available: available), extras: []))
    }

    @Test func escapeRequiresHoldAndCompleteRelease() throws {
        var gesture = try gesture()
        let result1 = !gesture.update(.init(buttons: menu | options), at: 10)
        #expect(result1)
        let result2 = !gesture.update(.init(buttons: options), at: 11)
        #expect(result2)
        let result3 = gesture.update(.init(), at: 11.1)
        #expect(result3)
        let result4 = !gesture.update(.init(), at: 12)
        #expect(result4)
    }

    @Test func shortHoldAndSupersetStopNeverOpenControls() throws {
        var gesture = try gesture()
        let result5 = !gesture.update(.init(buttons: menu | options), at: 10)
        #expect(result5)
        let result6 = !gesture.update(.init(), at: 10.9)
        #expect(result6)
        let result7 = !gesture.update(.init(buttons: menu | options), at: 12)
        #expect(result7)
        let result8 = !gesture.update(.init(buttons: menu | options | ControllerMappedButton.leftShoulder.rawValue), at: 13)
        #expect(result8)
        let result9 = !gesture.update(.init(buttons: menu | options), at: 14)
        #expect(result9)
        let result10 = !gesture.update(.init(), at: 15)
        #expect(result10)
    }

    @Test func fixedEscapeCannotBecomeStopButStrictSupersetCan() throws {
        let escape = ControllerLayoutShortcuts.escape(available: available)
        #expect(throws: ControllerLayoutError.invalidBindings) {
            try ControllerLayoutShortcuts(stop: escape).validate(available: available)
        }
        try ControllerLayoutShortcuts(stop: escape.union([.button(.leftShoulder)])).validate(available: available)
        #expect(ControllerLayoutShortcuts.escape(available: [.button(.leftStick), .button(.rightStick)])
            == [.button(.leftStick), .button(.rightStick)])
        #expect(ControllerLayoutShortcuts.escape(available: [.button(.a)]).isEmpty)
    }

    @Test func mappedButtonsCannotSynthesizePhysicalEscape() throws {
        var gesture = try gesture()
        let layout = ControllerLayout(bindings: [.init(.button(.a), .button(.menu)), .init(.button(.b), .button(.options))])
        var plan = try ControllerMappingPlan(layout: layout, available: available)
        let physical = ControllerMappingSample(buttons: ControllerMappedButton.a.rawValue | ControllerMappedButton.b.rawValue)
        let result11 = plan.apply(physical).buttons == menu | options
        #expect(result11)
        let result12 = !gesture.update(physical, at: 10)
        #expect(result12)
        let result13 = !gesture.update(.init(), at: 12)
        #expect(result13)
    }
}
