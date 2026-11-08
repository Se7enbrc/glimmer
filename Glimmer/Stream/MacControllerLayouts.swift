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
    private weak var returnWindow: NSWindow?
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
        if let window { window.parent?.removeChildWindow(window) }
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

    func showControls(returnTo: NSWindow? = nil) {
        guard let forwarder else { return }
        returnWindow = returnTo
        forwarder.inputOwnershipLost(reason: "controller controls")
        if let window { window.makeKeyAndOrderFront(nil); return }
        let scale = returnTo.map { MacStreamControlsView.scale(for: $0.frame.size) } ?? 1
        let view = NavigationStack {
            ControllerLayoutsView(initialScope: scope)
                .onExitCommand { [weak self] in self?.window?.close() }
                .toolbar {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { [weak self] in
                            self?.window?.close()
                        }
                        .controllerSettingsFocus { [weak self] in self?.window?.close() }
                        .keyboardShortcut(.cancelAction)
                    }
                }
        }
        .environment(\.streamControlsScale, returnTo == nil ? nil : scale)
        .streamFont(.title3, scale: scale)
        let window = NSWindow(contentViewController: NSHostingController(rootView:
            view.modifier(MacStreamGlassSurface())))
        window.title = "Controller layouts"
        let available = returnTo?.frame.size ?? CGSize(width: 900, height: 900)
        window.setContentSize(NSSize(width: max(460, min(680 * scale, available.width - 64)),
                                     height: max(360, min(760 * scale, available.height - 64))))
        window.styleMask = [.titled, .closable, .resizable, .fullSizeContentView]
        window.titlebarAppearsTransparent = true
        window.isOpaque = false
        window.backgroundColor = .clear
        window.isReleasedWhenClosed = false
        window.delegate = self
        if let parent = returnTo?.parent ?? returnTo {
            window.level = parent.level
            window.collectionBehavior = [.fullScreenAuxiliary]
            window.setFrameOrigin(NSPoint(x: parent.frame.midX - window.frame.width / 2,
                                          y: parent.frame.midY - window.frame.height / 2))
            parent.addChildWindow(window, ordered: .above)
        } else { window.center() }
        self.window = window
        window.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let closing = notification.object as? NSWindow, closing === window else { return }
        closing.parent?.removeChildWindow(closing)
        closing.contentViewController = nil
        window = nil
        (returnWindow ?? forwarder?.window)?.makeKeyAndOrderFront(nil)
    }

    private func editingChanged() {
        guard let forwarder else { return }
        if ControllerLayoutEditing.active {
            forwarder.inputOwnershipLost(reason: "controller layout editor")
            for state in forwarder.attachedControllers.values {
                state.controller?.extendedGamepad?.valueChangedHandler = nil
                state.controller?.input.unmapped?.elementValueDidChangeHandler = nil
                if let controller = state.controller { ControllerButtonRoutes.set(controller, nil) }
            }
            for state in forwarder.attachedControllers.values { state.restoreSystemState() }
        } else {
            reload()
            if forwarder.forwardsControllerEvents { forwarder.resyncControllers() }
        }
    }
}
