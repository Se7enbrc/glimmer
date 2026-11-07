// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AppKit
import GlimmerEngine
import Observation
import SwiftUI

@MainActor @Observable
final class MacStreamControls: NSObject, NSWindowDelegate {
    enum Page { case actions, help, quit }
    enum Action: String {
        case resume, stats, mouse, layouts, help, quit, disconnect, cancel, confirm, done
    }

    private weak var input: InputForwarder?
    private weak var stream: StreamWindow?
    private let slot: UInt8
    private let token: UUID
    private let quitGame: @MainActor () -> Void
    private var panel: NSPanel?
    private var repeats: [UInt8: LauncherControllerRepeat] = [:]
    private var samples: [UInt8: LauncherControllerInput] = [:]
    private var sampleTokens: [UInt8: UUID] = [:]
    private var timer: Timer?
    var selection = Action.resume
    var page = Page.actions
    var mouseMode: Bool
    var statsShown: Bool
    var controllerAvailable = true
    let title: String
    let pcName: String

    var actions: [Action] {
        switch page {
        case .actions: [.resume, .stats] + (controllerAvailable ? [.mouse] : [])
            + [.layouts, .help, .quit, .disconnect]
        case .help: [.done]
        case .quit: [.cancel, .confirm]
        }
    }

    init(input: InputForwarder, stream: StreamWindow, slot: UInt8, token: UUID,
         appName: String, pcName: String,
         quitGame: @escaping @MainActor () -> Void) {
        self.input = input
        self.stream = stream
        self.slot = slot
        self.token = token
        self.quitGame = quitGame
        title = appName
        self.pcName = pcName
        mouseMode = input.controllerMouseStates[slot]?.isMouse == true
        statsShown = stream.statsOverlay.isVisible
        super.init()
    }

    func show() {
        guard let input, let stream, panel == nil else { return }
        input.streamControls = self
        input.inputOwnershipLost(reason: "stream controls")
        input.exitCapturedMode()
        stream.setCursorHidden(false)
        let core = input.inputCore
        core.withLock {
            core.localControllerInput = { [weak self, weak core] slot, sample in
                let token = core?.controllerToken(slot: slot)
                // Preserve capture order across the main-thread handoff, including press/release pairs.
                DispatchQueue.main.async { [weak self] in self?.receive(slot: slot, token: token, sample: sample) }
            }
        }
        let host = NSHostingController(rootView: MacStreamControlsView(model: self))
        let panel = NSPanel(contentViewController: host)
        panel.title = "Stream controls"
        panel.identifier = NSUserInterfaceItemIdentifier("stream-controls")
        panel.styleMask = [.titled, .closable]
        panel.isReleasedWhenClosed = false
        panel.hidesOnDeactivate = false
        panel.collectionBehavior = [.fullScreenAuxiliary]
        panel.delegate = self
        panel.setContentSize(host.view.fittingSize)
        let parent = stream.window
        panel.level = parent.level
        panel.setFrameOrigin(NSPoint(x: parent.frame.midX - panel.frame.width / 2,
                                     y: parent.frame.midY - panel.frame.height / 2))
        parent.addChildWindow(panel, ordered: .above)
        self.panel = panel
        panel.makeKeyAndOrderFront(nil)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let input else { return }
        for state in input.attachedControllers.values {
            guard let controller = state.controller, let pad = controller.extendedGamepad else { continue }
            let sample = input.controllerLayouts?.sample(for: controller, slot: state.slot)?.physical
                ?? .init(buttons: input.pressedButtonFlags(pad: pad), analog: InputForwarder.controllerAnalog(pad))
            receive(slot: state.slot, token: input.controllerToken(slot: state.slot), sample: sample)
        }
        for state in input.attachedHIDControllers.values {
            let sample = state.device.state
            receive(slot: state.slot, token: input.controllerToken(slot: state.slot),
                    sample: .init(buttons: sample.buttons, analog: sample.analog))
        }
    }

    func windowDidResignKey(_ notification: Notification) {
        stopRepeating()
        samples.removeAll()
        repeats.removeAll()
        sampleTokens.removeAll()
    }

    func receive(slot: UInt8, token: UUID?, sample: ControllerMappingSample) {
        guard panel?.isKeyWindow == true, input?.isReady == true,
              let token, input?.controllerToken(slot: slot) == token else { return }
        if sampleTokens[slot] != token { repeats[slot] = nil }
        sampleTokens[slot] = token
        let analog = sample.gamepadAnalog
        let buttons = Int32(bitPattern: sample.buttons)
        let horizontal = buttons & StreamProtocol.RIGHT_FLAG != 0 ? Float(1)
            : buttons & StreamProtocol.LEFT_FLAG != 0 ? -1 : Float(analog.leftStickX) / 32767
        let vertical = buttons & StreamProtocol.UP_FLAG != 0 ? Float(1)
            : buttons & StreamProtocol.DOWN_FLAG != 0 ? -1 : Float(analog.leftStickY) / 32767
        samples[slot] = LauncherControllerInput(direction: .direction(x: horizontal, y: vertical),
            activate: buttons & StreamProtocol.A_FLAG != 0, dismiss: buttons & StreamProtocol.B_FLAG != 0)
        poll()
    }

    private func poll() {
        guard panel?.isKeyWindow == true, input?.isReady == true else { stopRepeating(); return }
        for (slot, sample) in samples {
            guard input?.controllerToken(slot: slot) == sampleTokens[slot] else {
                samples[slot] = nil
                repeats[slot] = nil
                sampleTokens[slot] = nil
                continue
            }
            var state = repeats[slot] ?? LauncherControllerRepeat()
            let commands = state.commands(sample, at: ProcessInfo.processInfo.systemUptime)
            repeats[slot] = state
            for command in commands where panel != nil { handle(command) }
        }
        guard panel != nil, samples.values.contains(where: { !$0.isNeutral }) else { stopRepeating(); return }
        if timer == nil {
            timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.poll() }
            }
        }
    }

    func handle(_ command: LauncherCommand) {
        switch command {
        case .activate: perform(selection)
        case .dismiss: if page == .actions { close() } else { page = .actions; selection = .resume }
        case .up, .left, .down, .right:
            let index = actions.firstIndex(of: selection) ?? 0
            selection = actions[min(actions.count - 1, max(0, index + (command == .up || command == .left ? -1 : 1)))]
        case .menu: break
        }
    }

    func perform(_ action: Action) {
        guard let input else { return }
        guard actions.contains(action) else { return }
        switch action {
        case .resume: close()
        case .stats:
            input.onStatsHotkey?()
            statsShown = stream?.statsOverlay.isVisible == true
        case .mouse:
            guard input.controllerToken(slot: slot) == token else { return }
            mouseMode.toggle()
            input.inputCore.withLock {
                input.inputCore.resetControllerMouse(slot: slot)
                input.inputCore.controllerMouseStates[slot] = ControllerMouseState(isMouse: mouseMode)
            }
            input.publishControllerMouseActive()
        case .layouts: input.controllerLayouts?.showControls(returnTo: panel)
        case .help: page = .help; selection = .done
        case .quit: page = .quit; selection = .cancel
        case .cancel, .done: page = .actions; selection = .resume
        case .confirm: close(resume: false); quitGame()
        case .disconnect: close(resume: false); input.onQuitHotkey?()
        }
    }

    private func stopRepeating() { timer?.invalidate(); timer = nil }

    func controllerRemoved(slot: UInt8) {
        samples[slot] = nil
        repeats[slot] = nil
        sampleTokens[slot] = nil
        if slot == self.slot {
            controllerAvailable = false
            if selection == .mouse { selection = .resume }
        }
        if samples.values.allSatisfy(\.isNeutral) { stopRepeating() }
    }

    func close(resume: Bool = true) {
        guard let panel else { return }
        let restore = resume && panel.isKeyWindow && NSApp.isActive
        stopRepeating()
        panel.delegate = nil
        panel.parent?.removeChildWindow(panel)
        panel.close()
        self.panel = nil
        input?.inputCore.withLock { input?.inputCore.localControllerInput = nil }
        input?.streamControls = nil
        if restore, let stream, !stream.didClose {
            stream.window.makeKeyAndOrderFront(nil)
            input?.installFirstResponder()
            input?.resyncControllers()
            stream.reengageForeground()
        }
    }

    func windowWillClose(_ notification: Notification) { close() }
}

extension InputForwarder {
    func controllerToken(slot: UInt8) -> UUID? {
        inputCore.controllerToken(slot: slot)
    }
}
