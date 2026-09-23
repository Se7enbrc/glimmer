//
//  ControllerArrivalTests.swift
//
//  What a controller arrival promises the PC, and how the slots it announced are kept honest
//  across a reconnect, when Sunshine still holds the last session's virtual pads.
//

import GameController
import Testing
@testable import Glimmer

@MainActor
struct ControllerArrivalTests {

    private typealias Arrival = InputForwarder.ControllerArrival

    /// A pad GameController has no haptics for is not offered rumble.
    @Test func rumbleNeedsHaptics() throws {
        let forwarder = InputForwarder()
        defer { forwarder.detach() }
        let pad = GCController.withExtendedGamepad()
        try #require(pad.haptics == nil)
        forwarder.attach(gamepad: pad)
        let caps = try #require(forwarder.attachedControllers[ObjectIdentifier(pad)]?.arrival.caps)
        #expect(caps & UInt16(StreamProtocol.LI_CCAP_RUMBLE) == 0)
        #expect(caps & UInt16(StreamProtocol.LI_CCAP_TRIGGER_RUMBLE) == 0)
        #expect(caps & UInt16(StreamProtocol.LI_CCAP_ANALOG_TRIGGERS) != 0)
    }

    /// MISC_FLAG is advertised only when a DualSense Mute actually reaches the PC.
    @Test func muteIsAdvertisedOnlyWhenForwarded() {
        let forwarder = InputForwarder()
        defer { forwarder.detach() }
        let pad = GCController.withExtendedGamepad()
        let misc = UInt32(bitPattern: StreamProtocol.MISC_FLAG)
        #expect(forwarder.supportedButtonMask(for: pad, forwardsMute: true) & misc == misc)
        #expect(forwarder.supportedButtonMask(for: pad, forwardsMute: false) & misc == 0)
    }

    /// A slot is stale when its pad left or became a different pad; an unchanged pad
    /// keeps its slot, and a slot never announced has nothing to remove.
    @Test func staleSlotsAreTheGoneAndTheChanged() {
        let xbox = Arrival(type: UInt8(StreamProtocol.LI_CTYPE_XBOX), supportedButtons: 0xFFFF, caps: 0x03)
        let dualSense = Arrival(type: UInt8(StreamProtocol.LI_CTYPE_PS), supportedButtons: 0xFFFF, caps: 0x3F)
        let announced: [UInt8: Arrival] = [0: xbox, 1: dualSense, 2: xbox]
        let current: [UInt8: Arrival] = [0: xbox, 1: xbox, 3: dualSense]
        #expect(InputForwarder.staleControllerSlots(announced: announced, current: current) == [1, 2])
        #expect(InputForwarder.staleControllerSlots(announced: [:], current: current).isEmpty)
        #expect(InputForwarder.staleControllerSlots(announced: current, current: current).isEmpty)
    }

    /// A pad unplugged while the link was down is retired when the stream comes back.
    /// One unplugged mid-stream stays on the ledger until the next stream start, in case
    /// its removal went into a link that had already died.
    @Test func aPadThatLeftIsRetired() throws {
        let forwarder = InputForwarder()
        defer { forwarder.detach() }
        let pad = GCController.withExtendedGamepad()
        forwarder.setReady(true)
        forwarder.attach(gamepad: pad)
        let slot = try #require(forwarder.attachedControllers[ObjectIdentifier(pad)]?.slot)
        #expect(forwarder.announcedControllers[slot] != nil)

        forwarder.setReady(false)
        forwarder.detach(gamepad: pad)
        #expect(forwarder.announcedControllers[slot] != nil)
        forwarder.setReady(true)
        #expect(forwarder.announcedControllers[slot] == nil)

        forwarder.attach(gamepad: pad)
        #expect(forwarder.announcedControllers[slot] != nil)
        forwarder.detach(gamepad: pad)
        #expect(forwarder.announcedControllers[slot] != nil)
        forwarder.setReady(false)
        forwarder.setReady(true)
        #expect(forwarder.announcedControllers[slot] == nil)
    }
}
