// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AppKit
import GlimmerEngine
import SwiftUI
import Testing
@testable import Glimmer

@MainActor
@Suite(.serialized)
struct MacStreamControlsTests {
    @Test(.timeLimit(.minutes(1))) func macMenuHoldRequestsControlsInsteadOfMouseMode() async {
        let input = InputForwarder()
        input.setBackend(InputRecordingBackend())
        input.isReady = true
        input.controllersNeedAnnouncement = false
        input.gamepadMask = 1
        let controller = NSObject()
        let id = ObjectIdentifier(controller)
        let neutral = InputForwarder.neutralControllerAnalog
        let token = input.inputCore.registerController(id: id, slot: 0, buttons: 0, analog: neutral)
        defer { input.detach() }
        await withCheckedContinuation { continuation in
            input.onControllerMenu = { slot in
                #expect(slot == 0)
                continuation.resume()
            }
            let time = ProcessInfo.processInfo.systemUptime + 1
            input.inputCore.receiveController(id: id, token: token, buttons: StreamProtocol.PLAY_FLAG,
                analog: neutral, chordButtons: StreamProtocol.PLAY_FLAG, capturedAt: time)
            input.inputCore.receiveController(id: id, token: token, buttons: 0,
                analog: neutral, chordButtons: 0, capturedAt: time + 2.1)
        }
        #expect(input.controllerMouseStates[0]?.isMouse != true)
    }

    @Test(arguments: [false, true], [MacStreamControls.Page.actions, .help, .quit])
    func menuFitsItsActionsInBothAppearances(dark: Bool, page: MacStreamControls.Page) async throws {
        let input = InputForwarder()
        let stream = StreamWindow(displayMode: .window)
        let menu = MacStreamControls(input: input, stream: stream, slot: 0, token: UUID(),
                                    appName: "Journey game", pcName: "Journey PC", quitGame: {})
        menu.page = page
        menu.selection = menu.actions[0]
        let view = NSHostingView(rootView: MacStreamControlsView(model: menu)
            .preferredColorScheme(dark ? .dark : .light))
        let size = view.fittingSize
        let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: .titled,
                              backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = view
        defer { window.close(); input.detach(); stream.close() }
        window.orderFront(nil)
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        #expect(size.width == 360)
        #expect(size.height > 100 && size.height < 600)
        let frame = try #require(view.superview)
        let bitmap = try #require(frame.bitmapImageRepForCachingDisplay(in: frame.bounds))
        frame.cacheDisplay(in: frame.bounds, to: bitmap)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(Array(png), named: "mac-stream-menu-\(page)-\(dark ? "dark" : "light").png")
    }

    @Test func controllerActionsFollowTheSharedOrderAndQuitNeedsConfirmation() {
        let input = InputForwarder()
        let stream = StreamWindow(displayMode: .window)
        var quits = 0
        let menu = MacStreamControls(input: input, stream: stream, slot: 0, token: UUID(),
                                    appName: "Game", pcName: "PC") { quits += 1 }
        defer { input.detach(); stream.close() }
        #expect(menu.actions == [.resume, .stats, .mouse, .layouts, .help, .quit, .disconnect])
        menu.handle(.down)
        #expect(menu.selection == .stats)
        menu.perform(.help)
        #expect(menu.actions == [.done])
        menu.handle(.dismiss)
        #expect(menu.page == .actions)
        #expect(menu.selection == .resume)
        menu.perform(.quit)
        #expect(menu.actions == [.cancel, .confirm])
        #expect(menu.selection == .cancel)
        menu.handle(.activate)
        #expect(quits == 0)
        menu.perform(.quit)
        menu.handle(.down)
        menu.handle(.activate)
        #expect(quits == 1)
    }

    @Test func mouseActionTargetsTheOpeningControllerAndRejectsReplacement() {
        let input = InputForwarder()
        let stream = StreamWindow(displayMode: .window)
        let controller = NSObject()
        let id = ObjectIdentifier(controller)
        let token = input.inputCore.registerController(id: id, slot: 1, buttons: 0,
                                                      analog: InputForwarder.neutralControllerAnalog)
        let menu = MacStreamControls(input: input, stream: stream, slot: 1, token: token,
                                    appName: "Game", pcName: "PC", quitGame: {})
        defer { input.detach(); stream.close() }
        menu.perform(.mouse)
        #expect(input.controllerMouseStates[1]?.isMouse == true)
        #expect(input.controllerMouseStates[0] == nil)
        input.inputCore.removeController(id: id)
        input.resetControllerMouse(slot: 1)
        _ = input.inputCore.registerController(id: id, slot: 1, buttons: 0,
                                              analog: InputForwarder.neutralControllerAnalog)
        menu.perform(.mouse)
        #expect(input.controllerMouseStates[1] == nil)
        menu.selection = .mouse
        menu.controllerRemoved(slot: 1)
        #expect(!menu.actions.contains(.mouse))
        #expect(menu.selection == .resume)
    }

    @Test func statsAndDisconnectUseTheSessionActions() {
        let input = InputForwarder()
        let stream = StreamWindow(displayMode: .window)
        var stops = 0
        input.onStatsHotkey = { stream.statsOverlay.setVisible(!stream.statsOverlay.isVisible) }
        input.onQuitHotkey = { stops += 1 }
        let menu = MacStreamControls(input: input, stream: stream, slot: 0, token: UUID(),
                                    appName: "Game", pcName: "PC", quitGame: {})
        defer { input.detach(); stream.close() }
        menu.perform(.stats)
        #expect(menu.statsShown)
        menu.perform(.stats)
        #expect(!menu.statsShown)
        menu.perform(.disconnect)
        #expect(stops == 1)
    }
}
