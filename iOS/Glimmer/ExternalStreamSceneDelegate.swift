// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import UIKit

@MainActor
final class ExternalStreamSceneDelegate: NSObject, UIWindowSceneDelegate {
    var window: UIWindow?

    static func configuration(for role: UISceneSession.Role) -> UISceneConfiguration {
        // Reusing the session's SwiftUI configuration makes its delegate forward back to itself.
        let configuration = UISceneConfiguration(name: nil, sessionRole: role)
        if StreamOutputCoordinator.supports(role) { configuration.delegateClass = ExternalStreamSceneDelegate.self }
        return configuration
    }

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession,
               options connectionOptions: UIScene.ConnectionOptions) {
        guard StreamOutputCoordinator.supports(session.role), let scene = scene as? UIWindowScene else { return }
        let window = UIWindow(windowScene: scene)
        let root = UIViewController()
        root.view.backgroundColor = .black
        window.rootViewController = root
        self.window = window
        StreamOutputCoordinator.shared.connect(id: session.persistentIdentifier, role: session.role, window: window)
    }

    func sceneDidDisconnect(_ scene: UIScene) {
        StreamOutputCoordinator.shared.disconnect(id: scene.session.persistentIdentifier)
        window = nil
    }

    func sceneDidBecomeActive(_ scene: UIScene) {
        guard let window else { return }
        StreamOutputCoordinator.shared.connect(id: scene.session.persistentIdentifier,
                                                role: scene.session.role, window: window)
    }

    func sceneWillResignActive(_ scene: UIScene) {
        StreamOutputCoordinator.shared.disconnect(id: scene.session.persistentIdentifier)
    }

    func windowScene(_ windowScene: UIWindowScene,
                     didUpdateEffectiveGeometry previousGeometry: UIWindowScene.Geometry) {
        window?.rootViewController?.view.setNeedsLayout()
    }
}

extension AppDelegate {
    func application(_ application: UIApplication, configurationForConnecting session: UISceneSession,
                     options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        ExternalStreamSceneDelegate.configuration(for: session.role)
    }
}
