// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GameController
import GlimmerEngine
import SwiftUI
import Synchronization

@MainActor
final class LauncherMenuController {
    private var buttons: [GCControllerButtonInput] = []
    private let controllers: () -> [GCController]

    init(controllers: @escaping () -> [GCController] = { GCController.controllers() }) {
        self.controllers = controllers
    }

    var openMenu: (() -> Void)?
    private var generation: UInt64 = 0

    func update(active: Bool, streaming: Bool) {
        if active && !streaming { start() } else { stop() }
    }

    func start() {
        stop()
        let attempt = generation
        // The stream owns Menu's pressed handler; the launcher listens on its own value handler.
        for controller in controllers() {
            guard let button = controller.extendedGamepad?.buttonMenu,
                  button.valueChangedHandler == nil else { continue }
            let wasPressed = Mutex(button.isPressed)
            button.valueChangedHandler = { @Sendable [weak self] _, _, pressed in
                let edge = wasPressed.withLock { previous in
                    let edge = pressed && !previous
                    previous = pressed
                    return edge
                }
                guard edge else { return }
                Task { @MainActor [weak self] in
                    guard let self, self.generation == attempt else { return }
                    self.openMenu?()
                }
            }
            buttons.append(button)
        }
    }

    func stop() {
        generation &+= 1
        for button in buttons { button.valueChangedHandler = nil }
        buttons.removeAll()
    }
}

struct LauncherControllerMenu: UIViewRepresentable {
    let model: LauncherModel
    let app: HostApp
    @Binding var requestedAppID: Int?

    func makeUIView(context: Context) -> Anchor { Anchor() }

    func updateUIView(_ view: Anchor, context: Context) {
        let button = view.button
        button.menu = UIMenu(children: [
            UIAction(title: "Resume") { _ in model.activateTile(app) },
            UIAction(title: "Quit \(app.name)…", attributes: .destructive) { _ in model.requestQuitFromMenu() }
        ])
        guard requestedAppID == app.id, model.runningApp?.id == app.id else { return }
        DispatchQueue.main.async {
            guard requestedAppID == app.id, button.window != nil else { return }
            requestedAppID = nil
            button.performPrimaryAction()
        }
    }

    final class Anchor: UIView {
        let button = UIButton(type: .system)

        init() {
            super.init(frame: .zero)
            accessibilityElementsHidden = true
            isUserInteractionEnabled = false
            button.showsMenuAsPrimaryAction = true
            button.isAccessibilityElement = false
            addSubview(button)
        }

        required init?(coder: NSCoder) { nil }

        override func layoutSubviews() {
            super.layoutSubviews()
            button.frame = bounds
        }
    }
}
