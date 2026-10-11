// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GameController
import Testing
@testable import Glimmer

@MainActor
struct ControllerButtonLayoutTests {
    @Test func positionIsTheDefaultAndLabelsSwapOnlyFaceButtons() {
        let pairs = [(StreamProtocol.A_FLAG, StreamProtocol.B_FLAG),
                     (StreamProtocol.X_FLAG, StreamProtocol.Y_FLAG)]
        let extras = StreamProtocol.PLAY_FLAG | StreamProtocol.BACK_FLAG | StreamProtocol.RB_FLAG
        for (first, second) in pairs {
            #expect(ControllerButtonLayout.apply(first | extras, useNintendoLabels: false) == first | extras)
            #expect(ControllerButtonLayout.apply(first | extras, useNintendoLabels: true) == second | extras)
            #expect(ControllerButtonLayout.apply(second | extras, useNintendoLabels: true) == first | extras)
            #expect(ControllerButtonLayout.apply(first | second, useNintendoLabels: true) == first | second)
        }
    }

    @Test func detectsNintendoTypesWithoutTreatingEveryEightBitDoAsNintendo() throws {
        let pro = try #require(NintendoControllerType.identify(category: "Switch Pro Controller", name: ""))
        let hidPro = try #require(NintendoControllerType.identify(category: "", name: "Nintendo Switch Pro Controller"))
        #expect(pro == hidPro)
        let left = try #require(NintendoControllerType.identify(category: "JoyConLeft", name: "Joy-Con (L)"))
        let right = try #require(NintendoControllerType.identify(category: "JoyConRight", name: "Joy-Con (R)"))
        #expect(left.id != right.id && left.id != pro.id)
        #expect(NintendoControllerType.identify(category: "HID", name: "8BitDo SN30 Pro") != nil)
        #expect(NintendoControllerType.identify(category: "HID", name: "8BitDo Pro 2") != nil)
        #expect(NintendoControllerType.identify(category: "HID", name: "8BitDo Lite 2") != nil)
        #expect(NintendoControllerType.identify(category: "HID", name: "8BitDo SN30 Pro for Xbox") == nil)
        #expect(NintendoControllerType.identify(category: "HID", name: "8BitDo Xbox") == nil)
        #expect(NintendoControllerType.identify(category: "Xbox One", name: "Xbox") == nil)
        #expect(NintendoControllerType.identify(category: "DualSense", name: "DualSense") == nil)
        #expect(NintendoControllerType.identify(category: "HID", name: "Generic", bottomSymbol: "b.circle") != nil)
    }

    @Test func settingsShowsOnlyConnectedTypesOnceAcrossBothInputPaths() throws {
        let pro = try #require(NintendoControllerType.identify(category: "Switch Pro Controller", name: ""))
        let joy = try #require(NintendoControllerType.identify(category: "JoyCon", name: ""))
        #expect(NintendoLayoutSettings.connectedTypes(native: [], hid: []).isEmpty)
        #expect(NintendoLayoutSettings.connectedTypes(native: [pro, pro], hid: [pro]) == [pro])
        #expect(NintendoLayoutSettings.connectedTypes(native: [pro], hid: [joy]) == [joy, pro])
        #expect(NintendoLayoutSettings.connectedTypes(native: [], hid: [joy]) == [joy])
    }

    @Test func preferenceIsSavedPerTypeAndDefaultsToPosition() throws {
        let defaults = try #require(UserDefaults(suiteName: "ControllerButtonLayoutTests." + UUID().uuidString))
        let pro = try #require(NintendoControllerType.identify(category: "Switch Pro Controller", name: ""))
        let joy = try #require(NintendoControllerType.identify(category: "JoyCon", name: ""))
        defaults.setVolatileDomain([:], forName: UserDefaults.registrationDomain)
        defaults.register(defaults: [pro.defaultsKey: false, joy.defaultsKey: false])
        #expect(!pro.usesLabels(in: defaults))
        #expect(!joy.usesLabels(in: defaults))
        defaults.setVolatileDomain([pro.defaultsKey: true], forName: UserDefaults.argumentDomain)
        #expect(pro.usesLabels(in: defaults))
        #expect(!joy.usesLabels(in: defaults))
    }

    @Test func hidPathSwapsForTheSelectedTypeAndKeepsChordsPositional() throws {
        let forwarder = InputForwarder()
        defer { forwarder.detach() }
        let backend = InputRecordingBackend()
        forwarder.setBackend(backend)
        forwarder.isReady = true
        let pro = try #require(NintendoControllerType.identify(category: "Switch Pro Controller", name: ""))
        forwarder.nintendoLayoutProvider = { $0 == pro }
        let state = (buttons: StreamProtocol.A_FLAG, analog: InputForwarder.neutralControllerAnalog)
        forwarder.pushHID(slot: 0, state: state, type: pro) { state }
        forwarder.pushHID(slot: 1, state: state) { state }
        #expect(backend.calls.map(\.buttons) == [StreamProtocol.B_FLAG, StreamProtocol.A_FLAG])
        forwarder.controllerQuitChordProvider = { .custom }
        forwarder.customControllerChordProvider = { [.faceDown] }
        forwarder.pushHID(slot: 0, state: state, type: pro) { state }
        #expect(forwarder.quitChordDwellSlot == 0)
        #expect(backend.calls.count == 2)
    }

    @Test func mouseClicksStayPositionalWhenNintendoLabelsAreEnabled() throws {
        let forwarder = InputForwarder()
        defer { forwarder.detach() }
        let backend = InputRecordingBackend()
        forwarder.setBackend(backend)
        forwarder.isReady = true
        forwarder.nintendoLayoutProvider = { _ in true }
        let pro = try #require(NintendoControllerType.identify(category: "Switch Pro Controller", name: ""))
        let analog = InputForwarder.neutralControllerAnalog
        forwarder.routeControllerMouse(slot: 0, buttons: StreamProtocol.PLAY_FLAG,
                                       analog: analog, chordHeld: false, now: 1)
        forwarder.routeControllerMouse(slot: 0, buttons: 0, analog: analog, chordHeld: false, now: 2)
        forwarder.pushHID(slot: 0, state: (StreamProtocol.A_FLAG, analog), type: pro) { (0, analog) }
        #expect(backend.pointer == [
            .button(action: Int8(StreamProtocol.BUTTON_ACTION_PRESS), button: StreamProtocol.BUTTON_LEFT)
        ])
    }

    @Test func gameControllerReportsAndForwardsFacePositions() throws {
        let controller = GCController.withExtendedGamepad()
        let pad = try #require(controller.extendedGamepad)
        let forwarder = InputForwarder()
        defer { forwarder.detach() }
        let backend = InputRecordingBackend()
        forwarder.setBackend(backend)
        forwarder.isReady = true
        let pro = try #require(NintendoControllerType.identify(category: "Switch Pro Controller", name: ""))
        forwarder.nintendoLayoutProvider = { $0 == pro }
        pad.buttonA.setValue(1)
        forwarder.sendGamepadUpdate(pad: pad, slot: 0)
        #expect(backend.calls.last?.buttons == StreamProtocol.A_FLAG)
        forwarder.sendGamepadUpdate(pad: pad, slot: 0, type: pro)
        #expect(backend.calls.last?.buttons == StreamProtocol.B_FLAG)
        pad.buttonA.setValue(0)
        pad.buttonY.setValue(1)
        forwarder.sendGamepadUpdate(pad: pad, slot: 0)
        #expect(backend.calls.last?.buttons == StreamProtocol.Y_FLAG)
        forwarder.sendGamepadUpdate(pad: pad, slot: 0, type: pro)
        #expect(backend.calls.last?.buttons == StreamProtocol.X_FLAG)
    }

    @Test func macOSSwitchProDBUsesPositionsBeforeTheOptionalLabelSwap() throws {
        let mapping = try #require(GameControllerDB.lookup(vendor: 0x057e, product: 0x2009, version: 0x0100))
        #expect(mapping.bindings["a"] == .button(0))
        #expect(mapping.bindings["b"] == .button(1))
        let bottom = mapping.translate(.init(buttons: [true, false, false, false]))
        #expect(bottom.buttons == StreamProtocol.A_FLAG)
        #expect(ControllerButtonLayout.apply(bottom.buttons, useNintendoLabels: true) == StreamProtocol.B_FLAG)
    }
}
