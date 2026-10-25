// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import UIKit

@MainActor
final class StreamOutputCoordinator {
    static let shared = StreamOutputCoordinator()

    private var outputs: [String: UIWindow] = [:]
    private weak var controller: StreamViewController?
    private weak var activeWindow: UIWindow?
    private var restoreDisplay: (@MainActor () -> Void)?
    private let prepareDisplay: @MainActor (UIWindow) -> (@MainActor () -> Void)
    private let screenIdentity: @MainActor (UIWindow) -> ObjectIdentifier?

    init(prepareDisplay: @escaping @MainActor (UIWindow) -> (@MainActor () -> Void) = StreamDisplayMode.prepare,
         screenIdentity: @escaping @MainActor (UIWindow) -> ObjectIdentifier? = {
             $0.windowScene.map { ObjectIdentifier($0.screen) }
         }) {
        self.prepareDisplay = prepareDisplay
        self.screenIdentity = screenIdentity
    }

    static func supports(_ role: UISceneSession.Role) -> Bool {
        role == .windowExternalDisplayNonInteractive
    }

    func connect(id: String, role: UISceneSession.Role, window: UIWindow) {
        guard Self.supports(role) else { return }
        outputs[id] = window
        updateOutput()
    }

    func disconnect(id: String) {
        outputs.removeValue(forKey: id)
        updateOutput()
    }

    func update(_ controller: StreamViewController) {
        guard self.controller == nil || self.controller === controller else { return }
        self.controller = controller
        updateOutput()
    }

    func end(_ controller: StreamViewController) {
        guard self.controller === controller else { return }
        move(controller.surface, to: controller.view)
        releaseDisplay()
        controller.model.finishDisplayChange(external: false)
        self.controller = nil
    }

    private func updateOutput() {
        guard let controller, controller.isViewLoaded, let window = controller.view.window,
              let screen = screenIdentity(window) else { return }
        let target = outputs.sorted { $0.key < $1.key }.first { _, window in
            guard let outputScreen = screenIdentity(window) else { return false }
            return outputScreen != screen
        }?.value
        guard target !== activeWindow else { return }
        controller.model.prepareForDisplayChange()
        // Keep the same renderer and decoder; moving the view only replaces the display clock binding.
        move(controller.surface, to: controller.view)
        releaseDisplay()
        if let target, let root = target.rootViewController {
            restoreDisplay = prepareDisplay(target)
            activeWindow = target
            move(controller.surface, to: root.view)
            target.isHidden = false
        }
        controller.model.finishDisplayChange(external: activeWindow != nil)
    }

    private func releaseDisplay() {
        activeWindow?.isHidden = true
        activeWindow = nil
        restoreDisplay?()
        restoreDisplay = nil
    }

    private func move(_ surface: StreamSurface, to view: UIView) {
        guard surface.superview !== view else { return }
        surface.removeFromSuperview()
        view.insertSubview(surface, at: 0)
        surface.frame = view.bounds
        surface.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        surface.setNeedsLayout()
    }
}
