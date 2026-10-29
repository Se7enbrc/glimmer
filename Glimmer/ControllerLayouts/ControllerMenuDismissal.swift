// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GameController
import SwiftUI
import Synchronization

@MainActor
final class ControllerMenuDismissal {
    private var buttons: [(GCControllerButtonInput, GCControllerButtonValueChangedHandler?)] = []
    private var generation: UInt64 = 0

    isolated deinit { stop() }

    func start(controllers: [GCController], perform: @escaping @MainActor () -> Void) {
        stop()
        let generation = generation
        for controller in controllers {
            guard let button = controller.extendedGamepad?.buttonB else { continue }
            buttons.append((button, button.pressedChangedHandler))
            let held = Mutex(button.isPressed)
            button.pressedChangedHandler = { @Sendable [weak self] _, _, pressed in
                let began = held.withLock { previous in
                    defer { previous = pressed }
                    return pressed && !previous
                }
                guard began else { return }
                if Thread.isMainThread {
                    MainActor.assumeIsolated { self?.receive(generation: generation, perform: perform) }
                } else {
                    Task { @MainActor [weak self] in self?.receive(generation: generation, perform: perform) }
                }
            }
        }
    }

    private func receive(generation: UInt64, perform: @MainActor () -> Void) {
        guard self.generation == generation, !ControllerLayoutEditing.active else { return }
        perform()
    }

    func stop() {
        generation &+= 1
        for (button, handler) in buttons { button.pressedChangedHandler = handler }
        buttons.removeAll()
    }
}

private struct ControllerMenuDismissalModifier: ViewModifier {
    let active: Bool
    let perform: @MainActor () -> Void
    @State private var dismissal = ControllerMenuDismissal()

    func body(content: Content) -> some View {
        content
            .onChange(of: active, initial: true) { _, _ in update() }
            .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidConnect)) { _ in update() }
            .onReceive(NotificationCenter.default.publisher(for: .GCControllerDidDisconnect)) { _ in update() }
            .onDisappear { dismissal.stop() }
    }

    private func update() {
        if active { dismissal.start(controllers: GCController.controllers(), perform: perform) } else { dismissal.stop() }
    }
}

extension View {
    func controllerMenuDismissal(active: Bool, perform: @escaping @MainActor () -> Void) -> some View {
        modifier(ControllerMenuDismissalModifier(active: active, perform: perform))
    }
}
