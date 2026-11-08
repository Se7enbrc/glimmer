// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AppKit
import GlimmerEngine
import ScreenCaptureKit
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
        let previous = NSApp.appearance
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let picture = NSHostingController(rootView:
            LinearGradient(colors: [.indigo, .teal, .orange.opacity(0.6)],
                           startPoint: .topLeading, endPoint: .bottomTrailing))
        let view = picture.view
        let window = stream.window
        // This window contains only a generated test picture, never a PC stream.
        window.sharingType = .readOnly
        window.contentViewController = picture
        window.setContentSize(CGSize(width: 1280, height: 900))
        defer { menu.close(); input.detach(); stream.close(); NSApp.appearance = previous }
        window.makeKeyAndOrderFront(nil)
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(250))
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let content = try await SCShareableContent.currentProcess
        let target = try #require(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
        let configuration = SCStreamConfiguration()
        configuration.width = Int(window.frame.width)
        configuration.height = Int(window.frame.height)
        configuration.includeChildWindows = true
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        if page == .actions {
            let before = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: configuration)
            let data = try #require(NSBitmapImageRep(cgImage: before).representation(using: .png, properties: [:]))
            Attachment.record(Array(data), named: "menu-test-picture-\(dark ? "dark" : "light").png")
        }
        menu.show()
        try await Task.sleep(for: .milliseconds(250))
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: configuration)
        let bitmap = NSBitmapImageRep(cgImage: image)
        let png = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(Array(png), named: "mac-stream-menu-\(page)-\(dark ? "dark" : "light").png")
    }

    @Test func hiddenMenuCannotReclaimFocusFromControllerLayouts() async throws {
        let input = InputForwarder()
        let stream = StreamWindow(displayMode: .window)
        let menu = MacStreamControls(input: input, stream: stream, slot: 0, token: UUID(),
                                    appName: "Game", pcName: "PC", quitGame: {})
        defer { menu.close(); input.detach(); stream.close() }
        stream.window.makeKeyAndOrderFront(nil)
        menu.show()
        let panel = try #require(stream.window.childWindows?.first { $0.identifier?.rawValue == "stream-controls" })
        #expect(panel.canBecomeKey)
        panel.orderOut(nil)
        #expect(!panel.canBecomeKey)
        panel.makeKeyAndOrderFront(nil)
        #expect(panel.canBecomeKey)
        #expect(panel.isVisible)
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

    @Test(arguments: [false, true])
    func layoutsUseTheStreamGlassPresentation(dark: Bool) async throws {
        let settings = IsolatedDefaults()
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ControllerLayoutsModel(url: directory.appendingPathComponent("layouts.json"), defaults: settings.defaults)
        await model.load()
        let device = ControllerLayoutRenderTests().fixture(.dualSenseEdge)
        try await recordLayout(NavigationStack {
            ControllerLayoutEditor(model: model, device: device, scope: .allGames)
        }, name: "layouts", dark: dark)
        let control = try #require(device.controls.first { $0.id == .button(.a) })
        try await recordLayout(NavigationStack {
            ControllerLayoutEditor(model: model, device: device, scope: .allGames)
                .controllerSettingsDestination(isPresented: .constant(true)) {
                    ControllerLayoutAssignment(model: model, device: device, scope: .allGames,
                        control: control, layout: model.baseline(device, scope: .allGames))
                }
        }, name: "assignment", dark: dark)
    }

    private func recordLayout<V: View>(_ content: V, name: String, dark: Bool) async throws {
        let previous = NSApp.appearance
        NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        let backdrop = NSWindow(contentViewController: NSHostingController(rootView:
            LinearGradient(colors: [.indigo, .teal, .orange.opacity(0.6)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)))
        backdrop.isReleasedWhenClosed = false
        backdrop.setContentSize(CGSize(width: 1280, height: 900))
        backdrop.orderFront(nil)
        defer { backdrop.close(); NSApp.appearance = previous }
        let host = NSHostingController(rootView: content.environment(\.streamControlsScale, 1)
            .streamFont(.title3).preferredColorScheme(dark ? .dark : .light).modifier(MacStreamGlassSurface()))
        let window = NSWindow(contentViewController: host)
        window.isReleasedWhenClosed = false
        window.title = name == "layouts" ? "Controller layouts" : "Change control"
        window.styleMask = [.titled, .closable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.setContentSize(CGSize(width: 680, height: 760))
        window.setFrameOrigin(NSPoint(x: backdrop.frame.midX - window.frame.width / 2,
                                      y: backdrop.frame.midY - window.frame.height / 2))
        backdrop.addChildWindow(window, ordered: .above)
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        defer { backdrop.removeChildWindow(window); window.contentViewController = nil; window.close() }
        host.view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        try await Task.sleep(for: .milliseconds(500))
        let windows = try await SCShareableContent.currentProcess
        let target = try #require(windows.windows.first { $0.windowID == CGWindowID(backdrop.windowNumber) })
        let configuration = SCStreamConfiguration()
        configuration.width = Int(backdrop.frame.width)
        configuration.height = Int(backdrop.frame.height)
        configuration.includeChildWindows = true
        configuration.showsCursor = false
        configuration.ignoreShadowsSingleWindow = true
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: configuration)
        let data = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        Attachment.record(Array(data), named: "mac-stream-\(name)-\(dark ? "dark" : "light").png")
    }

    @Test func menuFollowsStreamResizingAndCompactSelection() async throws {
        let input = InputForwarder()
        let stream = StreamWindow(displayMode: .window)
        let menu = MacStreamControls(input: input, stream: stream, slot: 0, token: UUID(),
            appName: "Journey game", pcName: "Journey PC", quitGame: {})
        let window = stream.window
        window.sharingType = .readOnly
        window.contentViewController = NSHostingController(rootView:
            LinearGradient(colors: [.indigo, .teal, .orange.opacity(0.6)],
                           startPoint: .topLeading, endPoint: .bottomTrailing))
        defer { menu.close(); input.detach(); stream.close() }
        window.makeKeyAndOrderFront(nil)
        menu.show()
        let panel = try #require(window.childWindows?.first { $0.identifier?.rawValue == "stream-controls" })
        for size in [CGSize(width: 640, height: 480), CGSize(width: 2560, height: 1440)] {
            window.setContentSize(size)
            menu.selection = .disconnect
            try await Task.sleep(for: .milliseconds(300))
            #expect(panel.frame == window.convertToScreen(window.contentLayoutRect))
            let content = try await SCShareableContent.currentProcess
            let target = try #require(content.windows.first { $0.windowID == CGWindowID(window.windowNumber) })
            let configuration = SCStreamConfiguration()
            configuration.width = Int(window.frame.width)
            configuration.height = Int(window.frame.height)
            configuration.includeChildWindows = true
            configuration.showsCursor = false
            configuration.ignoreShadowsSingleWindow = true
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(desktopIndependentWindow: target), configuration: configuration)
            let png = try #require(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
            Attachment.record(Array(png), named: "mac-stream-menu-\(Int(size.width)).png")
        }
    }
}
