// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GameController
import GlimmerEngine
import SwiftUI

#if os(macOS)
import AppKit

@MainActor
final class ControllerLayoutNavigationHub {
    static let shared = ControllerLayoutNavigationHub()
    private struct Surface { weak var view: NSView? }
    private struct FocusTarget { weak var view: ControllerLayoutFocusView? }
    private struct Entry {
        let source: ControllerLayoutCaptureSource
        let release: () -> Void
        let epoch: UUID
    }

    private var entries: [String: Entry] = [:]
    private var observations: [NSObjectProtocol] = []
    private var repeats: [String: LauncherControllerRepeat] = [:]
    private var samples: [String: ControllerMappingSample] = [:]
    private var surfaces: [ObjectIdentifier: Surface] = [:]
    private var focusTargets: [ObjectIdentifier: FocusTarget] = [:]
    private weak var focusedControl: ControllerLayoutFocusView?
    private var timer: Timer?
    private var menuDepth = 0
    private var lastMenuRead: TimeInterval = 0
    private weak var priorWindow: NSWindow?
    private let devices: () -> [ControllerLayoutDevice]

    init(devices: @escaping () -> [ControllerLayoutDevice] = { ControllerLayoutsModel.shared.devices }) {
        self.devices = devices
    }

    func addFocus(_ view: ControllerLayoutFocusView) { focusTargets[ObjectIdentifier(view)] = FocusTarget(view: view) }
    func removeFocus(_ view: ControllerLayoutFocusView) {
        focusTargets[ObjectIdentifier(view)] = nil
        if focusedControl === view { focusedControl = nil }
    }

    func focus(_ command: LauncherCommand, in window: NSWindow) -> Bool {
        guard command != .dismiss, command != .menu else { return false }
        let targets = focusTargets.values.compactMap(\.view).filter {
            $0.window === window && $0.enabled && !$0.isHiddenOrHasHiddenAncestor && !$0.bounds.isEmpty
        }.sorted { lhs, rhs in
            let left = lhs.convert(lhs.bounds, to: nil), right = rhs.convert(rhs.bounds, to: nil)
            let leftToolbar = left.midY > window.contentLayoutRect.maxY
            let rightToolbar = right.midY > window.contentLayoutRect.maxY
            if leftToolbar != rightToolbar { return !leftToolbar }
            return abs(left.midY - right.midY) > 2 ? left.midY > right.midY : left.minX < right.minX
        }
        guard !targets.isEmpty else { return false }
        let current = targets.firstIndex { $0.focused } ?? targets.firstIndex { $0 === focusedControl }
        let backwards = command == .up || command == .left
        let index = command == .activate ? current ?? 0
            : current.map { ($0 + (backwards ? targets.count - 1 : 1)) % targets.count } ?? 0
        let target = targets[index]
        if focusedControl !== target { focusedControl?.focus(false) }
        focusedControl = target
        // Consecutive controller moves cannot wait for SwiftUI's later focus reflection.
        for candidate in targets { candidate.focused = candidate === target }
        target.scrollToVisible(target.bounds)
        target.focus(true)
        if command == .activate { target.activate() }
        return true
    }

    func add(_ view: NSView) {
        surfaces[ObjectIdentifier(view)] = Surface(view: view)
        if observations.isEmpty { observe() }
        scheduleRefresh()
    }

    func remove(_ view: NSView) {
        surfaces[ObjectIdentifier(view)] = nil
        guard surfaces.isEmpty else { return }
        observations.forEach(NotificationCenter.default.removeObserver)
        observations.removeAll()
        releaseInputs()
        menuDepth = 0
    }

    private func observe() {
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect,
                     HIDGamepadManager.devicesDidChange, ControllerLayoutEditing.changed,
                     ControllerLayoutEditing.captureChanged, NSWindow.didBecomeKeyNotification,
                     NSWindow.didResignKeyNotification, NSApplication.didResignActiveNotification] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    if ControllerLayoutEditing.capture != nil { self?.releaseInputs() }
                    self?.scheduleRefresh()
                }
            })
        }
        for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let beginning = note.name == NSMenu.didBeginTrackingNotification
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.menuDepth = max(0, self.menuDepth + (beginning ? 1 : -1))
                    if self.menuDepth > 0, self.targetWindow != nil { self.startTimer() }
                }
            })
        }
    }

    private func scheduleRefresh() {
        Task { @MainActor [weak self] in self?.refresh() }
    }

    private var targetWindow: NSWindow? {
        guard NSApp.isActive, ControllerLayoutEditing.capture == nil else { return nil }
        for window in surfaces.values.compactMap({ $0.view?.window }) {
            if window.isKeyWindow { return window }
            if let sheet = window.attachedSheet, sheet.isKeyWindow { return sheet }
        }
        return nil
    }

    private func releaseInputs() {
        timer?.invalidate()
        timer = nil
        let previous = entries
        entries.removeAll()
        previous.values.forEach { $0.release() }
        repeats.removeAll()
        samples.removeAll()
        priorWindow = nil
    }

    private func refresh() {
        guard !surfaces.isEmpty, ControllerLayoutEditing.capture == nil else { return }
        let devices = devices().filter(\.connected)
        let live = Set(devices.map(\.id))
        for id in entries.keys where !live.contains(id) {
            entries.removeValue(forKey: id)?.release()
            repeats[id] = nil
            samples[id] = nil
        }
        for device in devices where entries[device.id] == nil {
            guard let source = device.captureSource ?? Self.systemSource(device.controller) else { continue }
            let epoch = UUID()
            let id = device.id
            let release = source.acquire { [weak self] sample, _ in
                // Menu tracking reads live input while queued callbacks wait; never replay those older edges.
                let capturedAt = ProcessInfo.processInfo.systemUptime
                DispatchQueue.main.async { [weak self] in
                    guard let self, entries[id]?.epoch == epoch, capturedAt > lastMenuRead else { return }
                    samples[id] = sample
                    poll()
                }
            }
            entries[id] = Entry(source: source, release: release, epoch: epoch)
            samples[id] = source.read()
        }
        poll()
    }

    private static func systemSource(_ controller: GCController?) -> ControllerLayoutCaptureSource? {
        guard let controller, let pad = controller.extendedGamepad else { return nil }
        return ControllerLayoutCaptureSource(controls: [], extras: [], read: { systemSample(pad) }, acquire: { receive in
            let previous = pad.valueChangedHandler
            pad.valueChangedHandler = { @Sendable pad, _ in
                receive(Self.systemSample(pad), ProcessInfo.processInfo.systemUptime)
            }
            return { pad.valueChangedHandler = previous }
        })
    }

    nonisolated private static func systemSample(_ pad: GCExtendedGamepad) -> ControllerMappingSample {
        let buttons: [(GCControllerButtonInput, ControllerMappedButton)] = [
            (pad.buttonA, .a), (pad.buttonB, .b), (pad.dpad.up, .up),
            (pad.dpad.down, .down), (pad.dpad.left, .left), (pad.dpad.right, .right)
        ]
        let flags = buttons.reduce(UInt32(0)) { $1.0.isPressed ? $0 | $1.1.rawValue : $0 }
        return ControllerMappingSample(buttons: Int32(bitPattern: flags), analog: InputForwarder.controllerAnalog(pad))
    }

    static func input(_ sample: ControllerMappingSample) -> LauncherControllerInput {
        let analog = sample.gamepadAnalog
        let buttons = sample.buttons
        let x: Float = buttons & ControllerMappedButton.right.rawValue != 0 ? 1
            : buttons & ControllerMappedButton.left.rawValue != 0 ? -1 : Float(analog.leftStickX) / 32767
        let y: Float = buttons & ControllerMappedButton.up.rawValue != 0 ? 1
            : buttons & ControllerMappedButton.down.rawValue != 0 ? -1 : Float(analog.leftStickY) / 32767
        return LauncherControllerInput(direction: .direction(x: x, y: y),
            activate: buttons & ControllerMappedButton.a.rawValue != 0,
            dismiss: buttons & ControllerMappedButton.b.rawValue != 0)
    }

    private func poll(repeating: Bool = false) {
        guard let window = targetWindow else {
            timer?.invalidate(); timer = nil; repeats.removeAll(); priorWindow = nil
            return
        }
        if window !== priorWindow { repeats.removeAll(); priorWindow = window }
        for (id, entry) in entries {
            // Native menus track on a nested run loop, so read live values while their callbacks wait.
            if menuDepth > 0 {
                lastMenuRead = ProcessInfo.processInfo.systemUptime
                samples[id] = entry.source.read()
            }
            guard let sample = samples[id] else { continue }
            var state = repeats[id] ?? LauncherControllerRepeat()
            let current = repeating && menuDepth == 0 ? Self.input(entry.source.read()) : nil
            let commands = state.commands(Self.input(sample), at: ProcessInfo.processInfo.systemUptime, current: current)
            repeats[id] = state
            for command in commands {
                guard targetWindow === window else { return }
                if menuDepth == 0, focus(command, in: window) { continue }
                Self.send(command, to: window, trackingMenu: menuDepth > 0)
            }
        }
        if menuDepth > 0 || samples.values.contains(where: { !Self.input($0).isNeutral }) { startTimer() } else {
            timer?.invalidate(); timer = nil
        }
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll(repeating: true) }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    static func send(_ command: LauncherCommand, to window: NSWindow, trackingMenu: Bool = false,
                     postEvent: ((NSEvent) -> Void)? = nil) {
        let traversing = !trackingMenu && (command == .up || command == .down)
        let key = traversing ? (code: UInt16(48), characters: "\t")
            : command == .activate && trackingMenu ? (code: UInt16(36), characters: "\r") : command.key
        let modifiers: NSEvent.ModifierFlags = traversing && command == .up ? [.shift] : []
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: modifiers,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: key.characters, charactersIgnoringModifiers: key.characters,
                isARepeat: false, keyCode: key.code) else { continue }
            if let postEvent { postEvent(event) } else if trackingMenu {
                NSApp.postEvent(event, atStart: false)
            } else if type != .keyDown || !window.performKeyEquivalent(with: event) {
                window.sendEvent(event)
            }
        }
    }
}

@MainActor
final class ControllerLayoutFocusView: NSView {
    var enabled = true
    var focused = false
    var focus: (Bool) -> Void = { _ in }
    var activate: () -> Void = {}

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { ControllerLayoutNavigationHub.shared.removeFocus(self) } else {
            ControllerLayoutNavigationHub.shared.addFocus(self)
        }
    }
}

struct ControllerLayoutFocusControl: NSViewRepresentable {
    let enabled: Bool
    let focused: Bool
    let focus: (Bool) -> Void
    let activate: () -> Void

    func makeNSView(context: Context) -> ControllerLayoutFocusView { ControllerLayoutFocusView() }
    func updateNSView(_ view: ControllerLayoutFocusView, context: Context) {
        view.enabled = enabled
        view.focused = focused
        view.focus = focus
        view.activate = activate
    }
    static func dismantleNSView(_ view: ControllerLayoutFocusView, coordinator: ()) {
        ControllerLayoutNavigationHub.shared.removeFocus(view)
    }
}

@MainActor
private final class ControllerLayoutNavigationView: NSView {
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { stop() } else { ControllerLayoutNavigationHub.shared.add(self) }
    }

    func stop() { ControllerLayoutNavigationHub.shared.remove(self) }
}

private struct ControllerLayoutNavigation: NSViewRepresentable {
    func makeNSView(context: Context) -> ControllerLayoutNavigationView { ControllerLayoutNavigationView() }
    func updateNSView(_ view: ControllerLayoutNavigationView, context: Context) {}
    static func dismantleNSView(_ view: ControllerLayoutNavigationView, coordinator: ()) { view.stop() }
}
#endif

extension View {
    @ViewBuilder func controllerLayoutNavigation() -> some View {
        #if os(macOS)
        background(ControllerLayoutNavigation().frame(width: 0, height: 0))
        #else
        self
        #endif
    }
}
