// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine

@MainActor
final class NativeInputLifetime {
    private var controllers: IOSControllerCapture?
    private(set) var touch: TouchGamepadCapture?
    private var focused = false
    private var physical = false
    private var focusRevision: UInt64 = 0

    func start(input: StreamInput, controllers suppliedControllers: IOSControllerCapture? = nil,
               touch suppliedTouch: TouchGamepadCapture? = nil) {
        let touch = suppliedTouch ?? TouchGamepadCapture(input: input)
        let controllers = suppliedControllers ?? IOSControllerCapture(input: input)
        self.touch = touch
        self.controllers = controllers
        controllers.beforeAttach = { [weak self] in
            guard let self else { return }
            self.touch?.detach()
        }
        controllers.refreshed = { [weak self] connected in
            guard let self else { return }
            physical = connected
            reconcileTouch()
        }
        controllers.start()
    }

    func focus(_ focused: Bool) {
        focusRevision &+= 1
        let revision = focusRevision
        if !focused { self.focused = false; touch?.setEnabled(false) }
        controllers?.setFocused(focused)
        guard revision == focusRevision else { return }
        self.focused = focused
        reconcileTouch()
    }

    private func reconcileTouch() {
        if physical { touch?.detach() } else {
            touch?.attach()
            touch?.setEnabled(focused)
        }
    }

    func observeControllers(_ changed: @escaping @MainActor (Bool) -> Void) { controllers?.observeConnections(changed) }

    func stop() {
        focused = false
        physical = false
        touch?.detach()
        controllers?.stop()
        controllers = nil
        touch = nil
    }
}
