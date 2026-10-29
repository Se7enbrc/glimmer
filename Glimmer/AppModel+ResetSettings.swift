// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine

extension AppModel {
    func resetSettings(includeGames: Bool, layouts: ControllerLayoutsModel = .shared) async throws {
        guard !isStreaming else { throw ControllerLayoutError.invalidDocument }
        try await layouts.reset(includeGames: includeGames)
        SettingsReset.reset(defaults: settingsDefaults)
        let fresh = AppModel(defaults: settingsDefaults)
        qualityPreset = fresh.qualityPreset
        customWidth = fresh.customWidth
        customHeight = fresh.customHeight
        customFPS = fresh.customFPS
        streamHDR = fresh.streamHDR
        bitrateMode = fresh.bitrateMode
        streamDisplayMode = fresh.streamDisplayMode
        leaveGamesRunning = fresh.leaveGamesRunning
        defaultLaunchApp = fresh.defaultLaunchApp
        muteMacWhileStreaming = fresh.muteMacWhileStreaming
        captureSysKeys = fresh.captureSysKeys
        rawHIDControllerEnabled = fresh.rawHIDControllerEnabled
        streamCoversNotch = fresh.streamCoversNotch
        streamUsesFullScreenSpace = fresh.streamUsesFullScreenSpace
        quitHotkey = fresh.quitHotkey
        statsHotkey = fresh.statsHotkey
        releasePointerHotkey = fresh.releasePointerHotkey
        miniPlayerHotkey = fresh.miniPlayerHotkey
        showStreamStats = fresh.showStreamStats
        streamStatsCorner = fresh.streamStatsCorner
        statsOverlayPreset = fresh.statsOverlayPreset
        statsOverlayCustomRows = fresh.statsOverlayCustomRows
        statsThresholds = fresh.statsThresholds
        showDiagnostics = fresh.showDiagnostics
        telemetryEnabled = fresh.telemetryEnabled
        // Setters update the live model; reset leaves absent keys following future defaults.
        SettingsReset.reset(defaults: settingsDefaults)
        loadHosts()
        persistQualitySettings()
    }
}
