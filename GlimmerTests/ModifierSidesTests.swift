//
//  ModifierSidesTests.swift
//
//  flagsChanged device bits → held modifier sides, so releasing one of two
//  held Shifts releases exactly that side on the host.
//

import AppKit
import Testing
@testable import Glimmer

struct ModifierSidesTests {

    private func flags(_ raw: UInt) -> NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: raw) }
    private let shift = NSEvent.ModifierFlags.shift.rawValue
    private let control = NSEvent.ModifierFlags.control.rawValue
    private let option = NSEvent.ModifierFlags.option.rawValue
    private let command = NSEvent.ModifierFlags.command.rawValue

    @Test func bothShiftsHeldThenOneReleased() {
        let both = ModifierSides.held(in: flags(shift | 0x2 | 0x4), includeCommand: false)
        #expect(both == [0xA0, 0xA1])
        let rightOnly = ModifierSides.held(in: flags(shift | 0x4), includeCommand: false)
        #expect(rightOnly == [0xA1])
        #expect(ModifierSides.held(in: flags(0), includeCommand: false).isEmpty)
    }

    @Test func eachSideMapsToItsOwnVK() {
        #expect(ModifierSides.held(in: flags(control | 0x1), includeCommand: false) == [0xA2])
        #expect(ModifierSides.held(in: flags(control | 0x2000), includeCommand: false) == [0xA3])
        #expect(ModifierSides.held(in: flags(option | 0x20), includeCommand: false) == [0xA4])
        #expect(ModifierSides.held(in: flags(option | 0x40), includeCommand: false) == [0xA5])
    }

    /// A synthetic event with the flag but no side bit counts as the left side.
    @Test func flagWithoutSideBitIsTheLeftSide() {
        #expect(ModifierSides.held(in: flags(shift), includeCommand: false) == [0xA0])
        #expect(ModifierSides.held(in: flags(control), includeCommand: false) == [0xA2])
    }

    /// Cmd is only a host key when sys-key capture is on.
    @Test func commandIsGatedOnCapture() {
        #expect(ModifierSides.held(in: flags(command | 0x8), includeCommand: false).isEmpty)
        #expect(ModifierSides.held(in: flags(command | 0x8), includeCommand: true) == [0x5B])
        #expect(ModifierSides.held(in: flags(command | 0x10), includeCommand: true) == [0x5C])
    }
}
