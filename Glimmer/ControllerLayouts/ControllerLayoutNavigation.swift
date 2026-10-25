// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GameController
import SwiftUI

#if os(macOS)
import AppKit

@MainActor
private final class ControllerLayoutNavigationHub {
    static let shared = ControllerLayoutNavigationHub()
    private struct Surface {
        weak var view: NSView?
    }
    private struct Entry {
        let controller: GCController
        let queue: DispatchQueue
        let handler: GCExtendedGamepadValueChangedHandler?
    }

    private var entries: [ObjectIdentifier: Entry] = [:]
    private var observations: [NSObjectProtocol] = []
    private var pressed: [ObjectIdentifier: UInt8] = [:]
    private var surfaces: [ObjectIdentifier: Surface] = [:]

    func add(_ view: NSView) {
        surfaces[ObjectIdentifier(view)] = Surface(view: view)
        guard observations.isEmpty else { return }
        for name in [Notification.Name.GCControllerDidConnect, .GCControllerDidDisconnect] {
            observations.append(NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        Task { @MainActor [weak self] in
            guard let self, !surfaces.isEmpty else { return }
            refresh()
        }
    }

    func remove(_ view: NSView) {
        surfaces[ObjectIdentifier(view)] = nil
        guard surfaces.isEmpty else { return }
        observations.forEach { NotificationCenter.default.removeObserver($0) }
        observations.removeAll()
        for entry in entries.values {
            entry.controller.extendedGamepad?.valueChangedHandler = entry.handler
            entry.controller.handlerQueue = entry.queue
        }
        entries.removeAll()
        pressed.removeAll()
    }

    private func refresh() {
        let controllers = GCController.controllers()
        let live = Set(controllers.map(ObjectIdentifier.init))
        for id in entries.keys where !live.contains(id) {
            if let entry = entries.removeValue(forKey: id) {
                entry.controller.extendedGamepad?.valueChangedHandler = entry.handler
                entry.controller.handlerQueue = entry.queue
            }
            pressed[id] = nil
        }
        for controller in controllers {
            let id = ObjectIdentifier(controller)
            guard entries[id] == nil, let pad = controller.extendedGamepad else { continue }
            entries[id] = Entry(controller: controller, queue: controller.handlerQueue, handler: pad.valueChangedHandler)
            controller.handlerQueue = .main
            pad.valueChangedHandler = { [weak self] pad, _ in
                MainActor.assumeIsolated { self?.receive(pad, id: id) }
            }
        }
    }

    private func receive(_ pad: GCExtendedGamepad, id: ObjectIdentifier) {
        let inputs = [pad.dpad.up, pad.dpad.down, pad.dpad.left, pad.dpad.right, pad.buttonA, pad.buttonB]
        var buttons: UInt8 = 0
        for (index, input) in inputs.enumerated() where input.isPressed { buttons |= 1 << index }
        let began = buttons & ~(pressed[id] ?? 0)
        pressed[id] = buttons
        guard let window = surfaces.values.compactMap({ $0.view?.window }).first(where: \.isKeyWindow), began != 0 else { return }
        if began & 1 != 0 { window.selectPreviousKeyView(nil) }
        if began & 2 != 0 { window.selectNextKeyView(nil) }
        let keys: [(UInt8, String, UInt16)] = [(4, "\u{F702}", 123), (8, "\u{F703}", 124), (16, " ", 49), (32, "\u{1B}", 53)]
        for (mask, characters, code) in keys where began & mask != 0 {
            guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [],
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters, charactersIgnoringModifiers: characters, isARepeat: false, keyCode: code)
            else { continue }
            if !window.performKeyEquivalent(with: event) { window.firstResponder?.keyDown(with: event) }
        }
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
