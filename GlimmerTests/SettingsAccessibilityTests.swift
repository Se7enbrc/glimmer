// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import AppKit
import ApplicationServices
import SwiftUI
import Testing
@testable import Glimmer

@MainActor
struct SettingsAccessibilityTests {
    private let settings = IsolatedDefaults()

    @Test func customFieldsExposeDistinctNamesAndValues() throws {
        let model = AppModel(defaults: settings.defaults)
        model.qualityPreset = .custom
        model.customWidth = 1920
        model.customHeight = 1080
        model.customFPS = 60
        let view = NSHostingView(rootView: QualityPane().environment(model))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 700, height: 1800),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.title = "Quality accessibility test"
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let result = Self.readFields(process: getpid())
        #expect(result.error == AXError.success.rawValue)
        #expect(result.fields.count == 3)
        for (label, value) in [("Width in pixels", "1920"), ("Height in pixels", "1080"),
                               ("Refresh rate in hertz", "60")] {
            let field = try #require(result.fields.first { $0.name == label }, "Fields: \(result.fields)")
            #expect(field.value == value)
        }
    }

    @Test(arguments: [false, true], ["ordinary", "long", "empty", "unavailable", "streaming"])
    func continuationLauncherBoard(dark: Bool, state: String) async throws {
        let model = AppModel(defaults: settings.defaults)
        model.hostPolling.systemSleeping = true
        model.displayProbe = { (3024, 1964, 120) }
        model.leaveGamesRunning = state == "long"
        let game = state == "long" ? "An adventure with a very long name that should remain readable" : "Adventure"
        let host = Host(id: "board-pc", name: "Living room PC", customName: nil,
                        localAddress: "192.0.2.1", manualAddress: nil,
                        apps: [LibraryApp(id: 7, name: game, hdr: false, hidden: false),
                               LibraryApp(id: 8, name: "Desktop", hdr: false, hidden: false)],
                        lastConnected: nil, serverCertPEM: nil, appVersion: nil, macAddress: nil)
        model.hosts = state == "empty" ? [] : [host]
        model.selectedHost = state == "empty" ? nil : host
        model.hostLiveStatus = HostLiveStatus(hostID: host.id,
            state: state == "unavailable" ? .asleep : .streamingApp(name: game),
            rttMs: 2, capturedAt: Date(), runningAppID: state == "unavailable" ? nil : 7)
        if state == "streaming" {
            model.lastLaunchAttempt = (host.apps[0], host)
            model.isStreaming = true
        }
        if state == "long" {
            model.continuationHistory.remember(.init(width: 1920, height: 1080, fps: 60, hdr: false), pc: host.id, app: 7)
        }
        let content = BoardSurface().environment(model).preferredColorScheme(dark ? .dark : .light)
        let view = NSHostingView(rootView: content)
        let size = view.fittingSize
        view.frame = NSRect(origin: .zero, size: size)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        try await Task.sleep(for: .milliseconds(200))
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(Array(data), named: "mac-launcher-\(dark ? "dark" : "light")-\(state).png")
        if state != "empty" {
            #expect(size.width == LauncherLayout.contentWidth + 2 * LauncherLayout.horizontalPadding)
        }
        #expect(size.height > 0)
        view.frame.size.height += 200
        view.layoutSubtreeIfNeeded()
        #expect(view.fittingSize.height == size.height)
    }

    @Test(arguments: [false, true], [false, true])
    func disconnectSettingBoard(dark: Bool, leaveRunning: Bool) throws {
        let model = AppModel(defaults: settings.defaults)
        model.leaveGamesRunning = leaveRunning
        let view = NSHostingView(rootView: Form { DisconnectSettings() }
            .formStyle(.grouped).environment(model).preferredColorScheme(dark ? .dark : .light)
            .frame(width: 620, height: 180))
        view.frame = NSRect(x: 0, y: 0, width: 620, height: 180)
        let window = NSWindow(contentRect: view.frame, styleMask: [.titled], backing: .buffered, defer: false)
        window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
        window.contentView = view
        window.orderFront(nil)
        defer { window.orderOut(nil) }
        view.layoutSubtreeIfNeeded()
        window.displayIfNeeded()
        let bitmap = try #require(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        let data = try #require(bitmap.representation(using: .png, properties: [:]))
        Attachment.record(Array(data), named: "mac-setting-\(dark ? "dark" : "light")-\(leaveRunning).png")
        #expect(model.leaveGamesRunning == leaveRunning)
    }

    private struct BoardSurface: View {
        @FocusState private var focus: LauncherFocus?
        @Environment(AppModel.self) private var model
        var body: some View {
            if model.hosts.isEmpty { EmptyPairingState(focus: $focus) } else { ConnectSurface(focus: $focus) }
        }
    }

    private struct Field: Sendable {
        let name: String?
        let value: String?
    }

    private static func readFields(process: pid_t) -> (fields: [Field], error: Int32) {
        let app = AXUIElementCreateApplication(process)
        var windows: CFTypeRef?
        let error = AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows)
        guard error == .success else { return ([], error.rawValue) }
        let window = (windows as? [AXUIElement] ?? []).first {
            value(kAXTitleAttribute, of: $0) as? String == "Quality accessibility test"
        }
        guard let window else { return ([], AXError.noValue.rawValue) }
        let fields = descendants(of: window).filter { value(kAXRoleAttribute, of: $0) as? String == kAXTextFieldRole }
        return (fields.map {
            Field(name: value(kAXDescriptionAttribute, of: $0) as? String ?? value(kAXTitleAttribute, of: $0) as? String,
                  value: value(kAXValueAttribute, of: $0) as? String)
        }, error.rawValue)
    }

    private static func value(_ name: String, of element: AXUIElement) -> CFTypeRef? {
        var result: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &result) == .success else { return nil }
        return result
    }

    private static func descendants(of element: AXUIElement) -> [AXUIElement] {
        let children = value(kAXChildrenAttribute, of: element) as? [AXUIElement] ?? []
        return children + children.flatMap { descendants(of: $0) }
    }
}
