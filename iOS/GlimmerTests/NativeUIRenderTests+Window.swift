// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import SwiftUI
import Testing
import UIKit

@MainActor
final class FixtureViewportController: UIViewController {
    private let content: UIViewController
    private let size: CGSize?
    var orientations: UIInterfaceOrientationMask
    private(set) var hasAppeared = false

    init(content: UIViewController, size: CGSize?, orientations: UIInterfaceOrientationMask) {
        self.content = content
        self.size = size
        self.orientations = orientations
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { nil }

    // A geometry request alone permits UIKit to restore the device's previous orientation.
    override var supportedInterfaceOrientations: UIInterfaceOrientationMask {
        content.supportedInterfaceOrientations.intersection(orientations)
    }

    override var prefersStatusBarHidden: Bool { content.prefersStatusBarHidden }

    override func viewDidLoad() {
        super.viewDidLoad()
        addChild(content)
        view.addSubview(content.view)
        content.didMove(toParent: self)
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        hasAppeared = true
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        content.view.frame = CGRect(origin: .zero, size: size ?? view.bounds.size)
    }
}

extension NativeUIRenderTests {
    func makeRenderRoot(_ host: UIViewController, name: String, size: CGSize?,
                        dark: Bool, textSize: DynamicTypeSize) -> FixtureViewportController {
        let root = FixtureViewportController(content: host, size: size, orientations: .all)
        root.overrideUserInterfaceStyle = dark ? .dark : .light
        root.traitOverrides.preferredContentSizeCategory = UIContentSizeCategory(textSize)
        if let size, name.hasPrefix("ipad-") {
            host.traitOverrides.horizontalSizeClass = size.width < 600 ? .compact : .regular
        }
        return root
    }

    func withRenderPresentation(_ root: UIViewController, scene: UIWindowScene,
                                body: (UIWindow) async throws -> Void) async throws {
        let window = try #require(scene.keyWindow)
        let presenter = try #require(window.rootViewController)
        let orientation = scene.effectiveGeometry.interfaceOrientation
        try #require(presenter.presentedViewController == nil)
        try await commitLayout(presenter.view)
        await finishTransition(presenter)
        root.modalPresentationStyle = .fullScreen
        await withCheckedContinuation { continuation in
            presenter.present(root, animated: false) { continuation.resume() }
        }
        var failure: Error?
        do { try await body(window) } catch { failure = error }
        // Dismiss the dialog first: collapsing both presentations leaves its orientation lock pending.
        if let presented = root.presentedViewController {
            await finishTransition(presented)
            await dismissRenderPresentation(from: root)
        }
        await finishTransition(root)
        await dismissRenderPresentation(from: presenter)
        root.traitOverrides.remove(UITraitPreferredContentSizeCategory.self)
        root.overrideUserInterfaceStyle = .unspecified
        if scene.traitCollection.userInterfaceIdiom != .pad {
            presenter.setNeedsUpdateOfSupportedInterfaceOrientations()
            try await commitLayout(presenter.view)
            try await observeGeometry(scene, request: {
                scene.requestGeometryUpdate(.iOS(interfaceOrientations:
                    UIInterfaceOrientationMask(rawValue: 1 << orientation.rawValue))) { @Sendable error in
                        Issue.record("The render fixture could not restore scene orientation: \(error)")
                    }
            }, matches: { scene.effectiveGeometry.interfaceOrientation == orientation })
        }
        await finishTransition(presenter)
        try await commitLayout(presenter.view)
        try #require(scene.keyWindow === window && presenter.presentedViewController == nil)
        if let failure { throw failure }
    }

    private func dismissRenderPresentation(from controller: UIViewController) async {
        await withCheckedContinuation { continuation in
            controller.dismiss(animated: false) { continuation.resume() }
        }
    }
}
