// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

public enum SettingsReset {
    public static let keys: Set<String> = [
        "qualityPreset", "customWidth", "customHeight", "customFPS", "streamHDR", "streamProfile",
        "streamDisplayMode", "bitrateMode", "bitrateBoostWifi", "adaptiveBandwidthEnabled",
        "leaveGamesRunning", "defaultLaunchApp", "muteMacWhileStreaming",
        "captureSysKeys", "disableMouseAccelWhileStreaming", "nintendoButtonLayout",
        "rawHIDControllerEnabled", "hidGamepadClaimAll", "pacerTickOffMain", "pacerTickRealtime",
        "quitHotkey", "statsHotkey", "releasePointerHotkey", "miniPlayerHotkey",
        "controllerQuitChord", "customControllerChord", "controllerMouseStick", "touchMouseEnabled",
        "cruiseTraversalEnabled", "cruiseVKnee", "cruiseVFull", "cruiseDragDeltaScale",
        "streamCoversNotch", "streamUsesFullScreenSpace", "launcherStyle", "launchAtLogin", "launchMinimized",
        "showStreamStats", "streamStatsCorner", "statsOverlayPreset", "statsOverlayCustomRows", "statsThresholds",
        "showDiagnostics", "telemetryEnabled", "diagFileLogDebug", "telemetryListenLAN"
    ]
    public static let prefixes = ["glimmer.codecPreference.", "glimmer.launcherStyle.", "ios.touchLayout."]

    public static func reset(defaults: UserDefaults) {
        for key in defaults.dictionaryRepresentation().keys
            where keys.contains(key) || prefixes.contains(where: key.hasPrefix) {
            defaults.removeObject(forKey: key)
        }
    }
}
