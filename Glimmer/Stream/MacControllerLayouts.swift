// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AppKit
import GameController
import GlimmerEngine
import SwiftUI

@MainActor
final class MacControllerLayouts: NSObject, NSWindowDelegate {
    static weak var active: MacControllerLayouts?
    private weak var forwarder: InputForwarder?
    let scope: ControllerLayoutScope
    private var readers: [ObjectIdentifier: ControllerLayoutReader] = [:]
    private var observation: NSObjectProtocol?
    private var editingObservation: NSObjectProtocol?
    private var hidObservation: NSObjectProtocol?
    private var window: NSWindow?
    private var loading: Task<Void, Never>?

    init(forwarder: InputForwarder, scope: ControllerLayoutScope) {
        self.forwarder = forwarder
        self.scope = scope
        super.init()
        Self.active = self
        loading = Task { [weak self] in
            await ControllerLayoutsModel.shared.load()
            guard !Task.isCancelled else { return }
            self?.reload()
        }
        observation = NotificationCenter.default.addObserver(forName: ControllerLayoutsModel.didChange,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reload() }
            }
        editingObservation = NotificationCenter.default.addObserver(forName: ControllerLayoutEditing.changed,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.editingChanged() }
            }
        hidObservation = NotificationCenter.default.addObserver(forName: HIDGamepadManager.devicesDidChange,
            object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.reloadHID() }
            }
    }

    isolated deinit { stop() }

    func stop() {
        if Self.active === self { Self.active = nil }
        loading?.cancel()
        loading = nil
        if let observation { NotificationCenter.default.removeObserver(observation) }
        observation = nil
        if let editingObservation { NotificationCenter.default.removeObserver(editingObservation) }
        editingObservation = nil
        if let hidObservation { NotificationCenter.default.removeObserver(hidObservation) }
        hidObservation = nil
        readers.removeAll()
        window?.delegate = nil
        window?.contentViewController = nil
        window?.close()
        window = nil
    }

    func release(_ controller: GCController) {
        let id = ObjectIdentifier(controller)
        readers[id] = nil
    }

    func configure(_ state: InputForwarder.AttachedController) -> (ControllerLayoutReader, ControllerLayoutConfiguration)? {
        guard !ControllerLayoutEditing.active, let forwarder, let controller = state.controller else { return nil }
        let model = ControllerLayoutsModel.shared
        guard model.loaded else { return nil }
        guard let reader = ControllerLayoutReader(controller) else {
            installSystemShortcuts(state, model: model)
            return nil
        }
        let record = model.library.resolve(reader.identity, scope: scope)
        guard let configuration = try? ControllerLayoutConfiguration(
            layout: record?.layout, shortcuts: model.shortcuts(for: reader.identity),
            available: reader.available, extras: reader.extras, mouse: model.mouse) else { return nil }
        let core = forwarder.inputCore
        let id = ObjectIdentifier(controller)
        core.configureLayout(configuration, slot: state.slot, held: reader.sample(),
                             at: ProcessInfo.processInfo.systemUptime, systemHeld: reader.systemSample())
        readers[id] = reader
        return (reader, configuration)
    }

    private func installSystemShortcuts(_ state: InputForwarder.AttachedController, model: ControllerLayoutsModel) {
        guard let forwarder, let controller = state.controller, let pad = controller.extendedGamepad else { return }
        let identity = ControllerLayoutIdentity(category: controller.productCategory, profile: "system", controls: [])
        let available = Set(ControllerMappedButton.allCases.map { ControllerLayoutSource.button($0) })
            .union([.trigger(.left), .trigger(.right)])
        guard let configuration = try? ControllerLayoutConfiguration(layout: nil, shortcuts: model.shortcuts(for: identity),
            available: available, mouse: model.mouse) else { return }
        forwarder.inputCore.configureLayout(configuration, slot: state.slot,
            held: .init(buttons: forwarder.pressedButtonFlags(pad: pad), analog: InputForwarder.controllerAnalog(pad)),
            at: ProcessInfo.processInfo.systemUptime)
    }

    func sample(for controller: GCController, slot: UInt8)
        -> (physical: ControllerMappingSample, game: ControllerMappingSample, supplement: UInt32?)? {
        let id = ObjectIdentifier(controller)
        guard let reader = readers[id] else { return nil }
        let sample = reader.sample()
        let maps = forwarder?.inputCore.withLock { forwarder?.inputCore.layouts?.states[Int(slot)]?.plan != nil } == true
        return (sample, maps ? sample : reader.systemSample(), Self.centerButtons(for: id))
    }

    nonisolated static func centerButtons(for id: ObjectIdentifier) -> UInt32? {
        guard let state = DualSenseHID.shared.state(for: id)?.buttons else { return nil }
        return (state.options ? ControllerMappedButton.menu.rawValue : 0)
            | (state.create ? ControllerMappedButton.options.rawValue : 0)
            | (state.ps ? ControllerMappedButton.home.rawValue : 0)
            | (state.mute ? ControllerMappedButton.share.rawValue : 0)
            | (state.l1 ? ControllerMappedButton.leftShoulder.rawValue : 0)
            | (state.r1 ? ControllerMappedButton.rightShoulder.rawValue : 0)
    }

    func configureHID(_ state: InputForwarder.AttachedHIDController) {
        guard !ControllerLayoutEditing.active, let forwarder else { return }
        let model = ControllerLayoutsModel.shared
        guard model.loaded else { return }
        let pad = state.device
        let identity = HIDControllerLayouts.identity(pad)
        let record = model.library.resolve(identity, scope: scope)
        let available = Set(HIDControllerLayouts.controls(pad).map(\.id))
        guard let configuration = try? ControllerLayoutConfiguration(
            layout: record?.layout, shortcuts: model.shortcuts(for: identity),
            available: available, extras: pad.layoutExtras.map(\.name), mouse: model.mouse) else { return }
        let core = forwarder.inputCore
        core.configureLayout(configuration, slot: state.slot,
                             held: pad.capture.layoutSample(indexes: pad.layoutExtras.map(\.index)),
                             at: ProcessInfo.processInfo.systemUptime)
    }

    private func reload() {
        guard !ControllerLayoutEditing.active, let forwarder else { return }
        for state in forwarder.attachedControllers.values {
            guard let controller = state.controller else { continue }
            release(controller)
            if let pad = controller.extendedGamepad {
                forwarder.inputCore.configureLayout(nil, slot: state.slot,
                    held: .init(buttons: forwarder.pressedButtonFlags(pad: pad), analog: InputForwarder.controllerAnalog(pad)),
                    at: ProcessInfo.processInfo.systemUptime)
            }
            forwarder.installInputHandlers(for: state)
        }
        reloadHID()
    }

    private func reloadHID() {
        guard !ControllerLayoutEditing.active, let forwarder else { return }
        for state in forwarder.attachedHIDControllers.values {
            let held = state.device.state
            forwarder.inputCore.configureLayout(nil, slot: state.slot,
                held: .init(buttons: held.buttons, analog: held.analog), at: ProcessInfo.processInfo.systemUptime)
            configureHID(state)
        }
    }

    func showControls() {
        guard let forwarder else { return }
        forwarder.inputOwnershipLost(reason: "controller controls")
        if let window { window.makeKeyAndOrderFront(nil); return }
        let view = NavigationStack {
            ControllerLayoutsView(initialScope: scope)
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { [weak self] in
                            self?.window?.close()
                        }
                    }
                }
        }
        let window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Controller layouts"
        window.setContentSize(NSSize(width: 620, height: 680))
        window.styleMask = [.titled, .closable, .resizable]
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.center()
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        closing.contentViewController = nil
        window = nil
        forwarder?.window?.makeKeyAndOrderFront(nil)
    }

    private func editingChanged() {
        guard let forwarder else { return }
        if ControllerLayoutEditing.active {
            forwarder.inputOwnershipLost(reason: "controller layout editor")
            for state in forwarder.attachedControllers.values {
                state.controller?.extendedGamepad?.valueChangedHandler = nil
                state.controller?.input.unmapped?.elementValueDidChangeHandler = nil
            }
            for state in forwarder.attachedControllers.values { state.restoreSystemState() }
        } else {
            reload()
            if forwarder.forwardsControllerEvents { forwarder.resyncControllers() }
        }
    }
}
