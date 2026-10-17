// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import SwiftUI

@main
@MainActor
struct GlimmerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @Environment(\.scenePhase) private var scenePhase
    @State private var launcher = LauncherModel.make()
    private let displayActivity = AppDisplayActivity()

    init() {
        UserDefaults.standard.register(defaults: ["telemetryEnabled": AppDisplayActivity.developmentBuild])
    }

    var body: some Scene {
        WindowGroup {
            LauncherView(model: launcher)
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
    static let orientationMask: UIInterfaceOrientationMask = .landscape

    func application(
        _ application: UIApplication,
        supportedInterfaceOrientationsFor window: UIWindow?
    ) -> UIInterfaceOrientationMask {
        Self.orientationMask
    }
}
