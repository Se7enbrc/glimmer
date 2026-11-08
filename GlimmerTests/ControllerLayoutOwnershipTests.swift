// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AppKit
import GlimmerEngine
import SwiftUI
import Testing
@testable import Glimmer

@MainActor
@Suite(.serialized)
struct ControllerLayoutOwnershipTests {
    @Test func savedGlobalQuitPreferencesRemainAvailableToTheLayoutRouter() {
        let settings = IsolatedDefaults()
        settings.defaults.set("none", forKey: "controllerQuitChord")
        let model = ControllerLayoutsModel(defaults: settings.defaults)
        let identity = ControllerLayoutIdentity(category: "Fixture", profile: "system", controls: [])
        #expect(model.shortcuts(for: identity).stop.isEmpty)
        #expect(model.shortcuts(for: identity).stats == ControllerLayoutShortcuts.defaultStats)
        #expect(settings.defaults.string(forKey: "controllerQuitChord") == "none")
    }

    @Test func closingWhileLayoutsLoadDoesNotStartDeviceObservationAfterDismissal() async throws {
        let identity = ControllerLayoutIdentity(category: "fixture", profile: "physical", controls: [])
        let record = ControllerLayoutRecord(key: .init(owner: .type(identity.type), scope: .allGames),
            name: "Saved controller", layout: .init(bindings: [.init(.button(.a), .button(.b))]))
        var pending: CheckedContinuation<Void, Never>?
        let model = ControllerLayoutsModel(read: {
            await withCheckedContinuation { pending = $0 }
            return .init(records: [record])
        })
        let window = NSWindow(contentViewController: NSHostingController(rootView: NavigationStack {
            ControllerLayoutsView(model: model)
        }))
        window.setContentSize(CGSize(width: 620, height: 500))
        window.makeKeyAndOrderFront(nil)
        try await waitUntil { pending != nil }
        window.contentViewController = nil
        window.close()
        pending?.resume()
        pending = nil
        await model.load()
        await DispatchQueue.main.drainForTest()
        #expect(model.loaded)
        #expect(model.devices.isEmpty)
        #expect(!ControllerLayoutEditing.active)
    }

    @Test func closingTheEditorReturnsMiniPlayerOwnershipAndReleasesTheEditor() async throws {
        let streamWindow = PointerFocusTestWindow(contentRect: .zero, styleMask: .borderless,
                                                   backing: .buffered, defer: true)
        streamWindow.focused = true
        let forwarder = InputForwarder()
        forwarder.window = streamWindow
        forwarder.isMiniPlayer = true
        forwarder.isReady = true
        let layouts = MacControllerLayouts(forwarder: forwarder, scope: .allGames)
        defer { layouts.stop(); forwarder.detach() }
        layouts.showControls()
        try await waitUntil { ControllerLayoutEditing.active }
        #expect(forwarder.controllerOwnershipSuspended)
        #expect(!forwarder.inputCore.snapshot.focused)
        let editor = try #require(NSApplication.shared.windows.first { $0.title == "Controller layouts" })
        editor.close()
        try await waitUntil { !ControllerLayoutEditing.active && !forwarder.controllerOwnershipSuspended }
        #expect(editor.contentViewController == nil)
        #expect(ControllerLayoutEditing.capture == nil)
    }

    @Test(arguments: [0, 3, 25], [false, true])
    func escapeFromTheControllerClosesLayoutsAndReturnsToTheMenu(level: Int, nested: Bool) async throws {
        let forwarder = InputForwarder()
        let menu = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 300),
                            styleMask: .titled, backing: .buffered, defer: false)
        menu.isReleasedWhenClosed = false
        menu.level = NSWindow.Level(rawValue: level)
        let stream = NSWindow(contentRect: menu.frame, styleMask: .titled, backing: .buffered, defer: false)
        stream.isReleasedWhenClosed = false
        stream.level = menu.level
        if nested { stream.addChildWindow(menu, ordered: .above) }
        let layouts = MacControllerLayouts(forwarder: forwarder, scope: .allGames)
        defer { layouts.stop(); forwarder.detach(); stream.removeChildWindow(menu); menu.close(); stream.close() }
        layouts.showControls(returnTo: menu)
        try await waitUntil { ControllerLayoutEditing.active }
        let editor = try #require(NSApplication.shared.windows.first { $0.title == "Controller layouts" })
        #expect(editor.parent === (nested ? stream : menu))
        #expect(editor.level == menu.level)
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: editor.windowNumber, context: nil,
            characters: "\u{1B}", charactersIgnoringModifiers: "\u{1B}", isARepeat: false, keyCode: 53))
        if !editor.performKeyEquivalent(with: event) { editor.firstResponder?.keyDown(with: event) }
        try await waitUntil { !ControllerLayoutEditing.active }
        #expect(editor.contentViewController == nil)
        #expect(editor.parent == nil)
        #expect(menu.isVisible)
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while !condition(), ContinuousClock.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        try #require(condition())
    }

    @Test func layoutRowsActivateFromTheControllerWithoutFullKeyboardAccess() async throws {
        var selected: [String] = []
        let window = NSWindow(contentViewController: NSHostingController(rootView: VStack {
            ControllerSettingsRow(title: "First") { selected.append("first") }
            ControllerSettingsRow(title: "Second") { selected.append("second") }
            Toggle("Enabled", isOn: .constant(false)).controllerSettingsFocus { selected.append("toggle") }
        }.padding().frame(width: 520)))
        window.isReleasedWhenClosed = false
        defer { window.contentViewController = nil; window.close() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        window.makeFirstResponder(window.contentView)
        ControllerLayoutNavigationHub.send(.down, to: window, postEvent: { window.sendEvent($0) })
        try await Task.sleep(for: .milliseconds(100))
        ControllerLayoutNavigationHub.send(.activate, to: window, postEvent: { window.sendEvent($0) })
        try await waitUntil { !selected.isEmpty }
        ControllerLayoutNavigationHub.send(.down, to: window, postEvent: { window.sendEvent($0) })
        try await Task.sleep(for: .milliseconds(100))
        ControllerLayoutNavigationHub.send(.activate, to: window, postEvent: { window.sendEvent($0) })
        try await waitUntil { selected.count == 2 }
        ControllerLayoutNavigationHub.send(.down, to: window, postEvent: { window.sendEvent($0) })
        try await Task.sleep(for: .milliseconds(100))
        ControllerLayoutNavigationHub.send(.activate, to: window, postEvent: { window.sendEvent($0) })
        try await waitUntil { selected.count == 3 }
        #expect(Set(selected) == ["first", "second", "toggle"])
    }

    @Test func controllerFocusSkipsUnavailableControlsAndStaysInItsWindow() throws {
        let hub = ControllerLayoutNavigationHub(devices: { [] })
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 400),
                              styleMask: .titled, backing: .buffered, defer: false)
        let other = NSWindow(contentRect: window.frame, styleMask: .titled, backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        other.isReleasedWhenClosed = false
        defer { window.close(); other.close() }
        var selected: [Int] = []
        var controls: [ControllerLayoutFocusView] = []
        for index in 0..<5 {
            let view = ControllerLayoutFocusView(frame: NSRect(x: 20, y: CGFloat(320 - index * 50), width: 300, height: 40))
            (index == 4 ? other : window).contentView?.addSubview(view)
            view.enabled = index != 1
            view.isHidden = index == 2
            view.focus = { [weak view] in view?.focused = $0 }
            view.activate = { selected.append(index) }
            hub.addFocus(view)
            controls.append(view)
        }
        #expect(hub.focus(.down, in: window))
        #expect(hub.focus(.activate, in: window))
        #expect(hub.focus(.down, in: window))
        #expect(hub.focus(.activate, in: window))
        #expect(hub.focus(.down, in: window))
        #expect(hub.focus(.activate, in: window))
        #expect(selected == [0, 3, 0])
        #expect(!hub.focus(.dismiss, in: window))
        #expect(hub.focus(.up, in: window))
        #expect(hub.focus(.activate, in: window))
        #expect(selected == [0, 3, 0, 3])
        controls.forEach(hub.removeFocus)
        #expect(!hub.focus(.activate, in: window))
    }

    @Test func physicalLayoutNavigationIncludesSticksAndPositionalFaceButtons() {
        let right = ControllerMappingSample(buttons: 0, analog: SIMD8(0, 0, 30000, 0, 0, 0, 0, 0))
        #expect(ControllerLayoutNavigationHub.input(right).direction == .right)
        let up = ControllerMappingSample(buttons: 0, analog: SIMD8(0, 0, 0, 30000, 0, 0, 0, 0))
        #expect(ControllerLayoutNavigationHub.input(up).direction == .up)
        let select = ControllerMappingSample(buttons: ControllerMappedButton.a.rawValue)
        #expect(ControllerLayoutNavigationHub.input(select).activate)
        #expect(!ControllerLayoutNavigationHub.input(select).dismiss)
        let back = ControllerMappingSample(buttons: ControllerMappedButton.b.rawValue)
        #expect(ControllerLayoutNavigationHub.input(back).dismiss)
    }

    @Test func controllerCanChooseAnOptionFromANativeMenu() async throws {
        var selection = 0
        let window = NSWindow(contentViewController: NSHostingController(rootView: VStack {
            ControllerSettingsPicker(title: "Choice", value: "", selection: Binding(
                get: { selection }, set: { selection = $0 })) {
                Text("First").tag(0)
                Text("Second").tag(1)
            }
        }.padding().frame(width: 520)))
        window.isReleasedWhenClosed = false
        defer { window.contentViewController = nil; window.close() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await Task.sleep(for: .milliseconds(200))
        window.makeFirstResponder(window.contentView)
        ControllerLayoutNavigationHub.send(.down, to: window, postEvent: { window.sendEvent($0) })
        try await Task.sleep(for: .milliseconds(100))
        var opened = false
        let observer = NotificationCenter.default.addObserver(forName: NSMenu.didBeginTrackingNotification,
            object: nil, queue: .main) { _ in MainActor.assumeIsolated { opened = true } }
        defer { NotificationCenter.default.removeObserver(observer) }
        let timer = Timer(timeInterval: 0.5, repeats: false) { _ in
            MainActor.assumeIsolated {
                // Menu opening can highlight the item under the pointer; start from the first item.
                if let home = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                    timestamp: 0, windowNumber: window.windowNumber, context: nil,
                    characters: String(UnicodeScalar(NSHomeFunctionKey) ?? "\u{F729}"),
                    charactersIgnoringModifiers: "", isARepeat: false, keyCode: 115) {
                    NSApp.postEvent(home, atStart: false)
                }
                ControllerLayoutNavigationHub.send(.down, to: window, trackingMenu: true)
                ControllerLayoutNavigationHub.send(.activate, to: window, trackingMenu: true)
            }
        }
        RunLoop.main.add(timer, forMode: .eventTracking)
        RunLoop.main.add(timer, forMode: .common)
        defer { timer.invalidate() }
        ControllerLayoutNavigationHub.send(.activate, to: window, postEvent: {
            if !$0.isARepeat, $0.type == .keyDown, window.performKeyEquivalent(with: $0) { return }
            NSApp.sendEvent($0)
        })
        try await waitUntil { selection == 1 }
        #expect(opened)
    }

    @Test func recordingTakesExclusiveOwnershipAndNavigationResumesAfterward() async throws {
        var leases = 0
        let source = ControllerLayoutCaptureSource(controls: [], extras: [], read: { .init() }, acquire: { _ in
            leases += 1
            return { leases -= 1 }
        })
        let device = ControllerLayoutDevice(id: "fixture", name: "Fixture", identity: nil, owner: .type("fixture"),
            reader: nil, controller: nil, controls: [], nintendoLabels: false, hidID: 1, captureSource: source)
        let hub = ControllerLayoutNavigationHub(devices: { [device] })
        let surface = NSView()
        let recording = UUID()
        defer { ControllerLayoutEditing.releaseCapture(recording); hub.remove(surface) }
        hub.add(surface)
        try await waitUntil { leases == 1 }
        #expect(ControllerLayoutEditing.acquireCapture(recording))
        #expect(leases == 0)
        await DispatchQueue.main.drainForTest()
        #expect(leases == 0)
        ControllerLayoutEditing.releaseCapture(recording)
        try await waitUntil { leases == 1 }
        hub.remove(surface)
        #expect(leases == 0)
        await DispatchQueue.main.drainForTest()
        #expect(leases == 0)
    }

    @Test(arguments: [false, true])
    func assignmentReturnsToTheGlassPaneWithoutClosingLayouts(save: Bool) async throws {
        let settings = IsolatedDefaults()
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let model = ControllerLayoutsModel(url: directory.appendingPathComponent("layouts.json"), defaults: settings.defaults)
        await model.load()
        let device = ControllerLayoutRenderTests().fixture(.dualSenseEdge)
        let control = try #require(device.controls.first { $0.id == .button(.a) })
        var returned = false
        var closed = false
        let window = NSWindow(contentViewController: NSHostingController(rootView:
            GlassAssignmentNavigationFixture(model: model, device: device, control: control,
                returned: { returned = true }, closed: { closed = true })))
        window.isReleasedWhenClosed = false
        window.setContentSize(CGSize(width: 680, height: 760))
        defer { window.contentViewController = nil; window.close() }
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
        try await waitUntil { ControllerLayoutEditing.active }
        try await Task.sleep(for: .milliseconds(250))
        let event = try #require(NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
            timestamp: 0, windowNumber: window.windowNumber, context: nil,
            characters: save ? "\r" : "\u{1B}", charactersIgnoringModifiers: save ? "\r" : "\u{1B}",
            isARepeat: false, keyCode: save ? 36 : 53))
        if !window.performKeyEquivalent(with: event) { window.sendEvent(event) }
        try await waitUntil { returned || closed }
        #expect(returned && !closed)
        #expect(model.library.records.isEmpty == !save)
        #expect(window.isVisible)
    }
}

private struct GlassAssignmentNavigationFixture: View {
    let model: ControllerLayoutsModel
    let device: ControllerLayoutDevice
    let control: ControllerLayoutControl
    let returned: () -> Void
    let closed: () -> Void
    @State private var presented = true

    var body: some View {
        NavigationStack {
            Text("Layouts")
                .toolbar { Button("Done", action: closed).keyboardShortcut(.cancelAction) }
                .controllerSettingsDestination(isPresented: $presented) {
                    ControllerLayoutAssignment(model: model, device: device, scope: .allGames,
                        control: control, layout: model.baseline(device, scope: .allGames))
                }
        }
        .environment(\.streamControlsScale, 1)
        .onChange(of: presented) { _, value in if !value { returned() } }
    }
}
