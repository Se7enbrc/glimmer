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
    private var leases: [ObjectIdentifier: ControllerLayoutInputLease] = [:]
    private var readers: [ObjectIdentifier: ControllerLayoutReader] = [:]
    private var hidReleases: [UInt64: @Sendable () -> Void] = [:]
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
        for lease in leases.values { lease.stop() }
        leases.removeAll()
        readers.removeAll()
        for release in hidReleases.values { release() }
        hidReleases.removeAll()
        window?.delegate = nil
        window?.contentViewController = nil
        window?.close()
        window = nil
    }

    func release(_ controller: GCController) {
        let id = ObjectIdentifier(controller)
        leases.removeValue(forKey: id)?.stop()
        readers[id] = nil
    }

    func install(_ state: InputForwarder.AttachedController) {
        guard !ControllerLayoutEditing.active, let forwarder, let controller = state.controller else { return }
        let model = ControllerLayoutsModel.shared
        guard model.loaded else { return }
        guard let reader = ControllerLayoutReader(controller) else {
            installSystemShortcuts(state, model: model)
            return
        }
        let record = model.library.resolve(reader.identity, scope: scope)
        guard let configuration = try? ControllerLayoutConfiguration(
            layout: record?.layout, shortcuts: model.shortcuts(for: reader.identity),
            available: reader.available, extras: reader.extras) else { return }
        let core = forwarder.inputCore
        let id = ObjectIdentifier(controller)
        let slot = state.slot
        let mapsGameInput = configuration.plan != nil
        let routesHID = state.retainedHID
        guard let token = core.withLock({ core.controllers[id]?.token }) else { return }
        core.configureLayout(configuration, slot: slot, held: reader.sample(), at: ProcessInfo.processInfo.systemUptime,
                             systemHeld: reader.systemSample())
        readers[id] = reader
        if let priorHomeGesture = state.priorHomeGesture {
            controller.physicalInputProfile.buttons[GCInputButtonHome]?.preferredSystemGestureState = priorHomeGesture
        }
        leases[id] = ControllerLayoutInputLease(controller: controller, reader: reader,
            queue: forwarder.controllerCaptureQueue, observeSystemInput: !mapsGameInput) { [core, reader] sample, now in
                if routesHID { DualSenseRouting.shared.gc(controller: id, buttons: sample.buttons, at: now) }
                let supplement = routesHID ? Self.centerButtons(for: id) : nil
                InputTimingContext.begin(source: .controller, timestamp: now)
                defer { InputTimingContext.end() }
                core.withLock {
                    guard let registered = core.controllers[id], registered.token == token,
                          now >= registered.registeredAt else { return }
                    let game = mapsGameInput ? sample : reader.systemSample()
                    core.controllers[id] = InputCore.ControllerSample(slot: slot, token: token,
                        registeredAt: registered.registeredAt, buttons: Int32(bitPattern: game.buttons),
                        analog: game.gamepadAnalog, extras: sample.extras)
                    core.receive(slot: slot, buttons: Int32(bitPattern: game.buttons), analog: game.gamepadAnalog,
                                 capturedAt: now, extras: sample.extras, physicalSample: sample,
                                 rawSupplement: supplement.map { (Int32(bitPattern: $0), Int32(bitPattern: $0)) })
                    if let touch = reader.touchSample(clicked: sample.buttons & ControllerMappedButton.touchpad.rawValue != 0) {
                        core.forwardTouchpad(slot: slot, primary: (touch.primaryX, touch.primaryY),
                            secondary: (touch.secondaryX, touch.secondaryY), clicked: touch.clicked, now: now)
                    }
                    core.retainMouseTiming(slot: slot)
                }
            }
    }

    private func installSystemShortcuts(_ state: InputForwarder.AttachedController, model: ControllerLayoutsModel) {
        guard let forwarder, let controller = state.controller, let pad = controller.extendedGamepad else { return }
        let identity = ControllerLayoutIdentity(category: controller.productCategory, profile: "system", controls: [])
        let available = Set(ControllerMappedButton.allCases.map { ControllerLayoutSource.button($0) })
            .union([.trigger(.left), .trigger(.right)])
        guard let configuration = try? ControllerLayoutConfiguration(layout: nil, shortcuts: model.shortcuts(for: identity),
            available: available) else { return }
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

    nonisolated private static func centerButtons(for id: ObjectIdentifier) -> UInt32? {
        guard let state = DualSenseHID.shared.state(for: id)?.buttons else { return nil }
        return (state.options ? ControllerMappedButton.menu.rawValue : 0)
            | (state.create ? ControllerMappedButton.options.rawValue : 0)
            | (state.ps ? ControllerMappedButton.home.rawValue : 0)
            | (state.mute ? ControllerMappedButton.share.rawValue : 0)
            | (state.l1 ? ControllerMappedButton.leftShoulder.rawValue : 0)
            | (state.r1 ? ControllerMappedButton.rightShoulder.rawValue : 0)
    }

    func releaseHID(_ id: UInt64) { hidReleases.removeValue(forKey: id)?() }

    func installHID(_ state: InputForwarder.AttachedHIDController) {
        releaseHID(state.device.id)
        guard !ControllerLayoutEditing.active, let forwarder else { return }
        let model = ControllerLayoutsModel.shared
        guard model.loaded else { return }
        let pad = state.device
        let identity = HIDControllerLayouts.identity(pad)
        let record = model.library.resolve(identity, scope: scope)
        let available = Set(HIDControllerLayouts.controls(pad).map(\.id))
        guard let configuration = try? ControllerLayoutConfiguration(
            layout: record?.layout, shortcuts: model.shortcuts(for: identity),
            available: available, extras: pad.layoutExtras.map(\.name)) else { return }
        let core = forwarder.inputCore
        let slot = state.slot
        guard let token = core.withLock({ core.hidRegistrations[slot] }) else { return }
        let indexes = pad.layoutExtras.map(\.index)
        core.configureLayout(configuration, slot: slot, held: pad.capture.layoutSample(indexes: indexes),
                             at: ProcessInfo.processInfo.systemUptime)
        hidReleases[pad.id] = pad.capture.acquireLayout(indexes: indexes) { sample, now in
            core.receiveHID(slot: slot, token: token, buttons: Int32(bitPattern: sample.buttons),
                            analog: sample.gamepadAnalog, capturedAt: now, extras: sample.extras)
        }
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
            releaseHID(state.device.id)
            let held = state.device.state
            forwarder.inputCore.configureLayout(nil, slot: state.slot,
                held: .init(buttons: held.buttons, analog: held.analog), at: ProcessInfo.processInfo.systemUptime)
            installHID(state)
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
            for lease in leases.values { lease.stop() }
            leases.removeAll()
            for state in forwarder.attachedControllers.values { state.restoreSystemState() }
            for release in hidReleases.values { release() }
            hidReleases.removeAll()
        } else {
            reload()
            if forwarder.forwardsControllerEvents { forwarder.resyncControllers() }
        }
    }
}
