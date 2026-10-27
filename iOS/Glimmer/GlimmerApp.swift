// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import SwiftUI

@main
@MainActor
struct GlimmerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var launcher: LauncherModel
    private let displayActivity = AppDisplayActivity()

    init() {
        #if DEBUG
        let model = UITestLauncher.make() ?? LauncherModel.make()
        #else
        let model = LauncherModel.make()
        #endif
        _launcher = State(initialValue: model)
        LauncherModel.intentModel = model
        StreamDefaults.register()
    }

    var body: some Scene {
        WindowGroup {
            LauncherView(model: launcher)
                .onOpenURL(perform: launcher.handleCommandURL)
                .onChange(of: launcher.savedPCs.map { PCEntity(id: $0.id, name: $0.name) }) { _, _ in
                    GlimmerShortcuts.updateAppShortcutParameters()
                }
        }
        .onChange(of: scenePhase, initial: true) { _, phase in
            displayActivity.update(phase, streamActive: launcher.hasActiveStream)
        }
        .onChange(of: launcher.hasActiveStream) { _, active in
            displayActivity.update(scenePhase, streamActive: active)
        }
    }
}

/// App-wide scene state owns auto-lock so a late stream teardown cannot undo foreground activity.
@MainActor
final class AppDisplayActivity {
    static var developmentBuild: Bool {
        #if DEBUG || GLIMMER_DEVELOPMENT
        true
        #else
        false
        #endif
    }

    private let development: Bool
    private let write: (Bool) -> Void

    init(development: Bool = AppDisplayActivity.developmentBuild,
         write: @escaping (Bool) -> Void = { UIApplication.shared.isIdleTimerDisabled = $0 }) {
        self.development = development
        self.write = write
    }

    func update(_ phase: ScenePhase, streamActive: Bool) {
        write(phase == .active && (development || streamActive))
    }
}

@MainActor
final class AppDelegate: NSObject, UIApplicationDelegate {
    static func menuOrientations(for idiom: UIUserInterfaceIdiom) -> UIInterfaceOrientationMask {
        idiom == .pad ? .all : .allButUpsideDown
    }

    static func streamOrientations(for idiom: UIUserInterfaceIdiom) -> UIInterfaceOrientationMask {
        idiom == .pad ? .all : .landscape
    }

    static func orientationMask(for window: UIWindow?) -> UIInterfaceOrientationMask {
        let idiom = window?.traitCollection.userInterfaceIdiom ?? UIDevice.current.userInterfaceIdiom
        if let window, let root = window.rootViewController, containsStream(root, in: window) {
            return streamOrientations(for: idiom)
        }
        return menuOrientations(for: idiom)
    }

    private static func containsStream(_ controller: UIViewController, in window: UIWindow) -> Bool {
        guard !controller.isBeingDismissed else { return false }
        if let presented = controller.presentedViewController, containsStream(presented, in: window) { return true }
        if let stream = controller as? StreamViewController,
           stream.presentationActive, stream.viewIfLoaded?.window === window { return true }
        return controller.children.contains { containsStream($0, in: window) }
    }

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        Self.orientationMask(for: window)
    }
}
