// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
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
        #expect(NintendoControllerType.identify(category: "JoyConLeft", name: "Joy-Con (L)") == nil)
        #expect(NintendoControllerType.identify(category: "JoyConRight", name: "Joy-Con (R)") == nil)
        #expect(NintendoControllerType.identify(category: "", name: "Joy-Con (L)", bottomSymbol: "b.circle") == nil)
        #expect(NintendoControllerType.identify(category: "", name: "Joy-Con (R) sideways") == nil)
        #expect(NintendoControllerType.identify(category: "JoyConLeft", name: "Unknown") == nil)
        #expect(NintendoControllerType.identify(category: "JoyConRight", name: "Unknown") == nil)
        #expect(NintendoControllerType.identify(category: "JoyConPair", name: "Joy-Con (L/R)") != nil)
        #expect(NintendoControllerType.identify(category: "HID", name: "8BitDo SN30 Pro") != nil)
        #expect(NintendoControllerType.identify(category: "HID", name: "8BitDo Pro 2") != nil)
        #expect(NintendoControllerType.identify(category: "HID", name: "8BitDo Lite 2") != nil)
        #expect(NintendoControllerType.identify(category: "HID", name: "8BitDo SN30 Pro for Xbox") == nil)
        #expect(NintendoControllerType.identify(category: "HID", name: "8BitDo Xbox") == nil)
        #expect(NintendoControllerType.identify(category: "Xbox One", name: "Xbox") == nil)
        #expect(NintendoControllerType.identify(category: "DualSense", name: "DualSense") == nil)
        #expect(NintendoControllerType.identify(category: "HID", name: "Generic", bottomSymbol: "b.circle") != nil)
    }

    @Test func settingsShowsOneToggleForAnyNintendoPadAcrossBothInputPaths() throws {
        let pro = try #require(NintendoControllerType.identify(category: "Switch Pro Controller", name: ""))
        let joy = try #require(NintendoControllerType.identify(category: "JoyCon", name: ""))
        #expect(!NintendoControllerPresence.connected(native: [], hid: []))
        #expect(NintendoControllerPresence.connected(native: [pro, pro], hid: [pro]))
        #expect(NintendoControllerPresence.connected(native: [pro], hid: [joy]))
        #expect(NintendoControllerPresence.connected(native: [], hid: [joy]))
        let single = NintendoControllerType.identify(category: "JoyConLeft", name: "Joy-Con (L)")
        #expect(!NintendoControllerPresence.connected(native: [single].compactMap { $0 }, hid: []))
    }

    @Test func settingsVisibilityFollowsConnectionEventsAndStopsObservingWhenHidden() {
        let presence = NintendoControllerPresence()
        var connected = true
        var reads = 0
        presence.start { reads += 1; return connected }
        defer { presence.stop() }
        #expect(presence.isConnected)
        presence.start { Issue.record("Repeated appearance must not install duplicate observers"); return false }
        #expect(presence.isConnected)
        for name in [Notification.Name.GCControllerDidDisconnect, .GCControllerDidConnect,
                     HIDGamepadManager.devicesDidChange, HIDGamepadManager.devicesDidChange] {
            connected.toggle()
            NotificationCenter.default.post(name: name, object: nil)
            #expect(presence.isConnected == connected)
        }
        #expect(reads == 5)
        presence.stop()
        connected = false
        NotificationCenter.default.post(name: .GCControllerDidDisconnect, object: nil)
        #expect(reads == 5)
        presence.start { connected }
        #expect(!presence.isConnected)
    }

    @Test func onePreferenceDefaultsToPositionWithoutMigratingUnreleasedTypeKeys() throws {
        let defaults = try #require(UserDefaults(suiteName: "ControllerButtonLayoutTests." + UUID().uuidString))
        defaults.setVolatileDomain([:], forName: UserDefaults.registrationDomain)
        defaults.setVolatileDomain(["nintendoButtonLayout.switchpro": true], forName: UserDefaults.argumentDomain)
        #expect(!ControllerButtonLayout.usesLabels(in: defaults))
        defaults.setVolatileDomain([ControllerButtonLayout.defaultsKey: true], forName: UserDefaults.argumentDomain)
        #expect(ControllerButtonLayout.usesLabels(in: defaults))
    }

    @Test func preferenceIsReadAtAttachAndOnDefaultsChangesInsteadOfEachFrame() throws {
        let forwarder = InputForwarder()
        defer { forwarder.detach() }
        let backend = InputRecordingBackend()
        forwarder.setBackend(backend)
        forwarder.isReady = true
        let pro = try #require(NintendoControllerType.identify(category: "Switch Pro Controller", name: ""))
        let joy = try #require(NintendoControllerType.identify(category: "JoyConPair", name: ""))
        var reads = 0
        forwarder.nintendoLayoutProvider = { reads += 1; return false }
        forwarder.registerNintendoController(slot: 0, type: pro)
        forwarder.registerNintendoController(slot: 1, type: joy)
        #expect(reads == 2)
        let state = (buttons: StreamProtocol.A_FLAG, analog: InputForwarder.neutralControllerAnalog)
        forwarder.nintendoLayoutProvider = { reads += 1; return true }
        for slot in UInt8(0)...1 { forwarder.pushHID(slot: slot, state: state) { state } }
        #expect(backend.calls.map(\.buttons) == [StreamProtocol.A_FLAG, StreamProtocol.A_FLAG])
        #expect(reads == 2)
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
        let afterNotification = reads
        #expect(afterNotification == 3)
        for slot in UInt8(0)...1 { forwarder.pushHID(slot: slot, state: state) { state } }
        #expect(backend.calls.suffix(2).map(\.buttons) == [StreamProtocol.B_FLAG, StreamProtocol.B_FLAG])
        #expect(reads == afterNotification)
        forwarder.removeGamepadObservers()
        NotificationCenter.default.post(name: UserDefaults.didChangeNotification, object: nil)
        #expect(reads == afterNotification)
    }

    @Test func nintendoAttachmentLogsTheBottomButtonSymbolOnceWithoutFrameLogs() throws {
        let forwarder = InputForwarder()
        defer { forwarder.detach() }
        let pro = try #require(NintendoControllerType.identify(category: "Switch Pro Controller", name: ""))
        let before = LogStore.shared.snapshot().last?.id ?? 0
        forwarder.registerNintendoController(slot: 12, type: pro, bottomSymbol: "b.circle")
        forwarder.registerNintendoController(slot: 13, type: nil, bottomSymbol: "a.circle")
        forwarder.isReady = true
        for _ in 0..<3 {
            forwarder.routeControllerMouse(slot: 12, buttons: 0,
                                           analog: InputForwarder.neutralControllerAnalog, chordHeld: false)
        }
        let entries = LogStore.shared.snapshot().filter { $0.id > before && $0.message.contains("sfSymbolsName") }
        #expect(entries.count == 1)
        #expect(entries.first?.message == "controller 12: Nintendo buttonA.sfSymbolsName=b.circle")
        #expect(entries.first?.level == .notice && entries.first?.category == "Controller")
    }

    @Test func hidPathLooksUpTheSlotTypeAndKeepsChordsPositional() throws {
        let forwarder = InputForwarder()
        defer { forwarder.detach() }
        let backend = InputRecordingBackend()
        forwarder.setBackend(backend)
        forwarder.isReady = true
        let pro = try #require(NintendoControllerType.identify(category: "Switch Pro Controller", name: ""))
        forwarder.nintendoLayoutProvider = { true }
        forwarder.registerNintendoController(slot: 0, type: pro)
        let state = (buttons: StreamProtocol.A_FLAG, analog: InputForwarder.neutralControllerAnalog)
        forwarder.pushHID(slot: 0, state: state) { state }
        forwarder.pushHID(slot: 1, state: state) { state }
        #expect(backend.calls.map(\.buttons) == [StreamProtocol.B_FLAG, StreamProtocol.A_FLAG])
        forwarder.controllerQuitChordProvider = { .custom }
        forwarder.customControllerChordProvider = { [.faceDown] }
        forwarder.pushHID(slot: 0, state: state) { state }
        #expect(forwarder.quitChordDwellSlot == 0)
        #expect(backend.calls.count == 2)
        forwarder.controllerQuitChordProvider = { .none }
        forwarder.registerNintendoController(slot: 0, type: nil)
        forwarder.pushHID(slot: 0, state: state) { state }
        #expect(backend.calls.last?.buttons == StreamProtocol.A_FLAG)
    }

    @Test func mouseClicksStayPositionalWhenNintendoLabelsAreEnabled() throws {
        let forwarder = InputForwarder()
        defer { forwarder.detach() }
        let backend = InputRecordingBackend()
        forwarder.setBackend(backend)
        forwarder.isReady = true
        forwarder.nintendoLayoutProvider = { true }
        let pro = try #require(NintendoControllerType.identify(category: "Switch Pro Controller", name: ""))
        forwarder.registerNintendoController(slot: 0, type: pro)
        let analog = InputForwarder.neutralControllerAnalog
        forwarder.routeControllerMouse(slot: 0, buttons: StreamProtocol.PLAY_FLAG,
                                       analog: analog, chordHeld: false, now: 1)
        forwarder.routeControllerMouse(slot: 0, buttons: 0, analog: analog, chordHeld: false, now: 2)
        forwarder.pushHID(slot: 0, state: (StreamProtocol.A_FLAG, analog)) { (0, analog) }
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
        forwarder.nintendoLayoutProvider = { true }
        forwarder.registerNintendoController(slot: 0, type: pro)
        pad.buttonA.setValue(1)
        forwarder.sendGamepadUpdate(pad: pad, slot: 1)
        #expect(backend.calls.last?.buttons == StreamProtocol.A_FLAG)
        forwarder.sendGamepadUpdate(pad: pad, slot: 0)
        #expect(backend.calls.last?.buttons == StreamProtocol.B_FLAG)
        forwarder.sendCenterButtonUpdate(pad: pad, slot: 0)
        #expect(backend.calls.last?.buttons == StreamProtocol.B_FLAG)
        pad.buttonA.setValue(0)
        pad.buttonY.setValue(1)
        forwarder.sendGamepadUpdate(pad: pad, slot: 1)
        #expect(backend.calls.last?.buttons == StreamProtocol.Y_FLAG)
        forwarder.sendGamepadUpdate(pad: pad, slot: 0)
        #expect(backend.calls.last?.buttons == StreamProtocol.X_FLAG)
        forwarder.sendCenterButtonUpdate(pad: pad, slot: 0)
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
