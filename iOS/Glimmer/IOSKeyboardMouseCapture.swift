// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GameController
import GlimmerEngine

@MainActor
final class IOSKeyboardMouseCapture {
    private let forwarder: IOSHardwareInput
    private let queue = DispatchQueue(label: "io.ugfugl.Glimmer.keyboardMouse", qos: .userInteractive)
    private let center: NotificationCenter
    private var observations: [NSObjectProtocol] = []
    private var keyboard: GCKeyboard?
    private var mice: [GCMouse] = []
    private var focused = false
    private var restore: [() -> Void] = []
    var connected: (Bool) -> Void = { _ in }

    init(input: StreamInput, quit: HotkeyChord, stats: HotkeyChord, center: NotificationCenter = .default) {
        forwarder = IOSHardwareInput(input: input, quit: quit, stats: stats)
        self.center = center
    }

    isolated deinit { stop() }

    func start() {
        guard observations.isEmpty else { return }
        for name in [Notification.Name.GCKeyboardDidConnect, .GCKeyboardDidDisconnect,
                     .GCMouseDidConnect, .GCMouseDidDisconnect] {
            observations.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.refresh() }
            })
        }
        refresh()
    }

    func setFocused(_ value: Bool) {
        guard value != focused else { return }
        focused = value
        refresh()
    }

    private func refresh() {
        detach()
        keyboard = GCKeyboard.coalesced
        mice = GCMouse.mice()
        if focused {
            let generation = forwarder.focus(true)
            if let keyboard { attach(keyboard, generation: generation) }
            for mouse in mice { attach(mouse, generation: generation) }
        }
        connected(keyboard != nil || !mice.isEmpty)
    }

    private func attach(_ keyboard: GCKeyboard, generation: UInt64) {
        guard let profile = keyboard.keyboardInput else { return }
        let priorQueue = keyboard.handlerQueue
        let priorHandler = profile.keyChangedHandler
        restore.append { keyboard.handlerQueue = priorQueue; profile.keyChangedHandler = priorHandler }
        keyboard.handlerQueue = queue
        let forwarder = forwarder
        profile.keyChangedHandler = { keyboard, _, code, pressed in
            forwarder.key(UInt16(clamping: code.rawValue), pressed: pressed, modifiers: Self.modifiers(keyboard),
                          at: ProcessInfo.processInfo.systemUptime, generation: generation)
        }
    }

    private func attach(_ mouse: GCMouse, generation: UInt64) {
        guard let profile = mouse.mouseInput else { return }
        let priorQueue = mouse.handlerQueue
        let priorMove = profile.mouseMovedHandler
        let priorScroll = profile.scroll.valueChangedHandler
        restore.append {
            mouse.handlerQueue = priorQueue
            profile.mouseMovedHandler = priorMove
            profile.scroll.valueChangedHandler = priorScroll
        }
        mouse.handlerQueue = queue
        let forwarder = forwarder
        profile.mouseMovedHandler = { _, x, y in
            forwarder.move(x: Double(x), y: Double(y), at: ProcessInfo.processInfo.systemUptime, generation: generation)
        }
        profile.scroll.valueChangedHandler = { _, x, y in
            forwarder.scroll(x: Double(x), y: Double(y),
                             at: ProcessInfo.processInfo.systemUptime, generation: generation)
        }
        attach(profile.leftButton, as: .left, generation: generation)
        if let button = profile.rightButton { attach(button, as: .right, generation: generation) }
        if let button = profile.middleButton { attach(button, as: .middle, generation: generation) }
        for (index, button) in (profile.auxiliaryButtons ?? []).prefix(2).enumerated() {
            attach(button, as: index == 0 ? .back : .forward, generation: generation)
        }
    }

    private func attach(_ button: GCControllerButtonInput, as pointer: PointerButton, generation: UInt64) {
        let priorHandler = button.pressedChangedHandler
        restore.append { button.pressedChangedHandler = priorHandler }
        let forwarder = forwarder
        button.pressedChangedHandler = { _, _, pressed in
            forwarder.button(pointer, pressed: pressed,
                             at: ProcessInfo.processInfo.systemUptime, generation: generation)
        }
    }

    nonisolated private static let modifierKeys: [(Int, Int, UInt8)] = [
        (224, 228, 2), (225, 229, 1), (226, 230, 4), (227, 231, 8)
    ]

    nonisolated private static func modifiers(_ keyboard: GCKeyboardInput) -> UInt8 {
        var result: UInt8 = 0
        for (left, right, flag) in modifierKeys {
            if keyboard.button(forKeyCode: GCKeyCode(rawValue: left))?.isPressed == true
                || keyboard.button(forKeyCode: GCKeyCode(rawValue: right))?.isPressed == true { result |= flag }
        }
        return result
    }

    private func detach() {
        forwarder.focus(false)
        for action in restore { action() }
        restore.removeAll(keepingCapacity: true)
        keyboard = nil
        mice.removeAll(keepingCapacity: true)
    }

    func stop() {
        focused = false
        detach()
        for observation in observations { center.removeObserver(observation) }
        observations.removeAll()
    }
}
