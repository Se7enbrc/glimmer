// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import SwiftUI
import UIKit

@MainActor
final class FixtureViewportController: UIViewController {
    private let content: UIViewController
    private let size: CGSize?
    private let orientations: UIInterfaceOrientationMask
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
    func makeRenderWindow(_ host: UIViewController, scene: UIWindowScene, name: String, size: CGSize?,
                          dark: Bool, textSize: DynamicTypeSize,
                          orientations: UIInterfaceOrientationMask) -> (UIWindow, FixtureViewportController) {
        let window = UIWindow(windowScene: scene)
        window.overrideUserInterfaceStyle = dark ? .dark : .light
        window.frame = scene.effectiveGeometry.coordinateSpace.bounds
        window.traitOverrides.preferredContentSizeCategory = textSize == .accessibility5
            ? .accessibilityExtraExtraExtraLarge : (textSize == .large ? .large : .extraExtraExtraLarge)
        host.overrideUserInterfaceStyle = dark ? .dark : .light
        let root = FixtureViewportController(content: host, size: size, orientations: orientations)
        if let size, name.hasPrefix("ipad-") {
            host.traitOverrides.horizontalSizeClass = size.width < 600 ? .compact : .regular
        }
        window.rootViewController = root
        return (window, root)
    }
}
