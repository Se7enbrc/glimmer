// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AppKit
import GameController
import SwiftUI

@MainActor
final class LauncherController {
    weak var window: NSWindow?
    weak var sheetWindow: NSWindow?
    var handle: ((LauncherCommand) -> Void)?
    var handleSheet: ((LauncherCommand) -> Void)?
    private var streaming = false
    private var testing = false
    private var menuDepth = 0
    private var observers: [NSObjectProtocol] = []
    private var timer: Timer?
    private var controllers: [GCController] = []
    private var repeats: [ObjectIdentifier: LauncherControllerRepeat] = [:]
    private let navigationEnabled: (() -> Bool)?
    private let availableControllers: () -> [GCController]
    private let now: () -> TimeInterval
    private let keyWindow: () -> NSWindow?
    private let postEvent: (NSEvent) -> Void
    var isPolling: Bool { timer != nil }

    init(navigationEnabled: (() -> Bool)? = nil,
         availableControllers: @escaping () -> [GCController] = { GCController.controllers() },
         now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
         keyWindow: @escaping () -> NSWindow? = { NSApp.keyWindow },
         postEvent: @escaping (NSEvent) -> Void = { NSApp.postEvent($0, atStart: false) }) {
        self.navigationEnabled = navigationEnabled
        self.availableControllers = availableControllers
        self.now = now
        self.keyWindow = keyWindow
        self.postEvent = postEvent
    }

    func attach(window: NSWindow?) {
        guard self.window !== window else { return }
        stop()
        self.window = window
        observeWindows()
        refresh()
    }

    func attachSheet(window: NSWindow?) {
        guard sheetWindow !== window else { return }
        stop()
        sheetWindow = window
        observeWindows()
        refresh()
    }

    func resetInput() { repeats.removeAll() }

    private func observeWindows() {
        guard observers.isEmpty, window != nil || sheetWindow != nil else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didResignKeyNotification,
                     NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        for name in [NSMenu.didBeginTrackingNotification, NSMenu.didEndTrackingNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                let beginning = note.name == NSMenu.didBeginTrackingNotification
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.menuDepth += beginning ? 1 : -1
                    self.menuDepth = max(0, self.menuDepth)
                }
            })
        }
    }

    func detach() {
        window = nil
        stop()
        if sheetWindow == nil { removeObservers() } else { refresh() }
    }

    func detachSheet() {
        sheetWindow = nil
        handleSheet = nil
        stop()
        if window == nil { removeObservers() } else { refresh() }
    }

    private func removeObservers() {
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        menuDepth = 0
    }

    func streamingChanged(_ streaming: Bool) {
        self.streaming = streaming
        refresh()
    }

    func testingChanged(_ testing: Bool) {
        self.testing = testing
        refresh()
    }

    private var canNavigate: Bool {
        guard !streaming else { return false }
        if let navigationEnabled { return navigationEnabled() }
        if let sheetWindow {
            return !streaming && !testing && NSApp.isActive && sheetWindow.isVisible && sheetWindow.isKeyWindow
        }
        guard let window, window.isVisible else { return false }
        return LauncherNavigation.isEnabled(streaming: streaming, testing: testing, active: NSApp.isActive,
                                            launcherKey: window.isKeyWindow,
                                            sheetKey: NSApp.keyWindow?.sheetParent === window)
    }

    /// Lifecycle's existing connect/disconnect observers refresh this list, as they do the controller chip.
    func refresh() {
        guard canNavigate else { stop(); return }
        let live = availableControllers()
        let liveIDs = Set(live.map(ObjectIdentifier.init))
        for controller in controllers where !liveIDs.contains(ObjectIdentifier(controller)) {
            controller.extendedGamepad?.valueChangedHandler = nil
            repeats[ObjectIdentifier(controller)] = nil
        }
        controllers.removeAll { !liveIDs.contains(ObjectIdentifier($0)) }
        for controller in live where !controllers.contains(where: { $0 === controller }) {
            guard let pad = controller.extendedGamepad, pad.valueChangedHandler == nil else { continue }
            // GameController refreshes values only with a handler; never replace another consumer's slot.
            // The callback wakes repeats; a neutral controller needs no timer.
            pad.valueChangedHandler = { @Sendable [weak self] _, _ in
                Task { @MainActor [weak self] in self?.inputChanged() }
            }
            controllers.append(controller)
        }
        guard !controllers.isEmpty else { stop(); return }
        poll()
    }

    func inputChanged(inputs: [ObjectIdentifier: LauncherControllerInput]? = nil) {
        guard timer == nil else { return }
        poll(inputs: inputs)
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = Timer(timeInterval: 1.0 / 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        self.timer = timer
        RunLoop.main.add(timer, forMode: .common)
        RunLoop.main.add(timer, forMode: .eventTracking)
    }

    private func stop() {
        timer?.invalidate()
        timer = nil
        for controller in controllers { controller.extendedGamepad?.valueChangedHandler = nil }
        controllers.removeAll()
        repeats.removeAll()
    }

    private func currentInputs() -> [ObjectIdentifier: LauncherControllerInput] {
        var inputs: [ObjectIdentifier: LauncherControllerInput] = [:]
        for controller in controllers {
            guard let pad = controller.extendedGamepad else { continue }
            let direction = LauncherCommand.direction(x: pad.dpad.xAxis.value, y: pad.dpad.yAxis.value)
                ?? LauncherCommand.direction(x: pad.leftThumbstick.xAxis.value, y: pad.leftThumbstick.yAxis.value)
            inputs[ObjectIdentifier(controller)] = LauncherControllerInput(
                direction: direction, activate: pad.buttonA.isPressed, dismiss: pad.buttonB.isPressed,
                menu: pad.buttonMenu.isPressed)
        }
        return inputs
    }

    func poll(inputs: [ObjectIdentifier: LauncherControllerInput]? = nil) {
        guard canNavigate else { stop(); return }
        let inputs = inputs ?? currentInputs()
        for (id, input) in inputs {
            var repeatState = repeats[id] ?? LauncherControllerRepeat()
            let commands = repeatState.commands(input, at: now())
            repeats[id] = repeatState
            for command in commands {
                guard canNavigate else { return }
                if menuDepth > 0 {
                    postKey(command)
                } else if sheetWindow != nil || window?.attachedSheet != nil {
                    if let handleSheet { handleSheet(command) } else if command == .dismiss { postKey(command) }
                } else {
                    handle?(command)
                }
            }
        }
        guard canNavigate else { stop(); return }
        if inputs.values.contains(where: { !$0.isNeutral }) {
            startTimer()
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    /// Local AppKit events let native menus and cancel buttons keep their own keyboard behavior, without TCC.
    func postKey(_ command: LauncherCommand) {
        guard canNavigate, let target = keyWindow() else { return }
        let key = command == .activate && menuDepth > 0 ? (code: UInt16(36), characters: "\r") : command.key
        for type in [NSEvent.EventType.keyDown, .keyUp] {
            if let event = NSEvent.keyEvent(with: type, location: .zero, modifierFlags: [],
                                           timestamp: ProcessInfo.processInfo.systemUptime,
                                           windowNumber: target.windowNumber, context: nil,
                                           characters: key.characters, charactersIgnoringModifiers: key.characters,
                                           isARepeat: false, keyCode: key.code) {
                postEvent(event)
            }
        }
    }
}

struct LauncherControllerWindow: NSViewRepresentable {
    let controller: LauncherController
    let handle: (LauncherCommand) -> Void
    var isSheet = false

    func makeNSView(context: Context) -> WindowReader {
        let view = WindowReader()
        view.controller = controller
        view.isSheet = isSheet
        if isSheet { controller.handleSheet = handle } else { controller.handle = handle }
        return view
    }

    func updateNSView(_ view: WindowReader, context: Context) {
        if isSheet { controller.handleSheet = handle } else { controller.handle = handle }
        view.attach()
    }

    static func dismantleNSView(_ view: WindowReader, coordinator: ()) {
        if view.isSheet {
            view.controller?.detachSheet()
        } else {
            view.controller?.detach()
            view.controller?.handle = nil
        }
    }

    final class WindowReader: NSView {
        weak var controller: LauncherController?
        var isSheet = false

        func attach() {
            if isSheet { controller?.attachSheet(window: window) } else { controller?.attach(window: window) }
        }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attach()
        }
    }
}
