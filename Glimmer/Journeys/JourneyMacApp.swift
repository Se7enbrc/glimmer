// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

#if DEBUG
import AppKit
import GlimmerEngine
import SwiftUI

// The journey uses the shipping views with isolated PC services, without normal startup's credentials or helpers.
struct JourneyMacApp: App {
    @State private var model: AppModel

    init() {
        precondition(PersistentStorage.isTesting && !NSWorkspace.shared.isVoiceOverEnabled)
        precondition(Bundle.main.bundleIdentifier == "io.ugfugl.Glimmer.JourneyHost")
        NSApplication.shared.appearance = NSAppearance(named: ProcessInfo.processInfo.environment["JOURNEY_APPEARANCE"] == "dark"
                                                    ? .darkAqua : .aqua)
        let defaults = PersistentStorage.defaults
        GlimmerApp.registerDefaults(defaults: defaults)
        for key in ["telemetryEnabled", "showDiagnostics", "rawHIDControllerEnabled",
                    "muteMacWhileStreaming", "disableMouseAccelWhileStreaming", "awdlHelperEnabled"] {
            defaults.set(false, forKey: key)
        }
        for key in ["awdlHelperPromptSuppressed", "rawHIDPromptAnswered"] { defaults.set(true, forKey: key) }
        let pc = JourneyMacPC()
        JourneyMacPC.active = pc
        _model = State(wrappedValue: pc.launcher())
    }

    var body: some Scene {
        Window("Glimmer", id: "main") {
            MainWindow().environment(model).tint(Color("AccentColor"))
                .frame(minWidth: LauncherLayout.windowWidth).glassWindowBackground()
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
        .restorationBehavior(.disabled)
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandMenu("Stream") { StreamMenu(model: model) }
        }
        Settings {
            SettingsRoot().environment(model).frame(minWidth: 680, minHeight: 540)
        }
    }
}
#endif
