//
//  ControllerArrivalTests.swift
//
//  What a controller arrival promises the PC: only the rumble and buttons Glimmer can deliver.
//

import GameController
import Testing
@testable import Glimmer

@MainActor
struct ControllerArrivalTests {

    /// A pad GameController has no haptics for is not offered rumble.
    @Test func rumbleNeedsHaptics() throws {
        let forwarder = InputForwarder()
        defer { forwarder.detach() }
        let pad = GCController.withExtendedGamepad()
        try #require(pad.haptics == nil)
        forwarder.attach(gamepad: pad)
        let caps = try #require(forwarder.attachedControllers[ObjectIdentifier(pad)]?.capabilities)
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
}
