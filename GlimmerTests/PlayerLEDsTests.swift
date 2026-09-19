//
//  PlayerLEDsTests.swift
//
//  Sunshine's SET_PLAYER_LEDS four-bit mask → GameController player index.
//

import GameController
import Testing
@testable import Glimmer

struct PlayerLEDsTests {

    @Test func lowestLitIndicatorNamesThePlayer() {
        #expect(PlayerLEDs.playerIndex(solidMask: 0x1) == .index1)
        #expect(PlayerLEDs.playerIndex(solidMask: 0x2) == .index2)
        #expect(PlayerLEDs.playerIndex(solidMask: 0x4) == .index3)
        #expect(PlayerLEDs.playerIndex(solidMask: 0x8) == .index4)
        #expect(PlayerLEDs.playerIndex(solidMask: 0x6) == .index2)
    }

    /// An empty mask clears the indicator; bits above the four used are ignored.
    @Test func emptyAndOutOfRangeMasks() {
        #expect(PlayerLEDs.playerIndex(solidMask: 0) == .indexUnset)
        #expect(PlayerLEDs.playerIndex(solidMask: 0xF0) == .indexUnset)
        #expect(PlayerLEDs.playerIndex(solidMask: 0xF1) == .index1)
    }
}
