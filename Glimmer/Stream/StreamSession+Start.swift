// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import Foundation
import AppKit

extension StreamSession {
    func start(
        server: ServerInfo,
        config: StreamConfig,
        appID: Int,
        quitHotkeyProvider: @escaping @MainActor () -> HotkeyChord = { .defaultQuit },
        statsHotkeyProvider: @escaping @MainActor () -> HotkeyChord = { .defaultStats },
        bookmarkHotkeyProvider: @escaping @MainActor () -> HotkeyChord = { .defaultBookmark },
        releasePointerHotkeyProvider: @escaping @MainActor () -> HotkeyChord = { .defaultReleasePointer },
        releaseInputHotkeyProvider: @escaping @MainActor () -> HotkeyChord = { .defaultReleaseInput },
        miniPlayerHotkeyProvider: @escaping @MainActor () -> HotkeyChord = { .defaultMiniPlayer },
        initialStatsOverlay: Bool = false,
        initialStatsCorner: StatsOverlayCorner = .topLeft,
        // Provider closure rather than a captured Set so toggling rows in
        // Settings mid-stream takes effect on the next 1Hz overlay tick.
        // Default = everything except audio, which matches the prior
        // "show all rows" surface for callers that haven't migrated to
        // the preset model yet.
        statsRowsProvider: @escaping @MainActor () -> Set<StatsRow.Kind> = {
            StatsOverlayDefaults.extendedRows
        },
        statsThresholdsProvider: @escaping @MainActor () -> StatsThresholds = { .default },
        controllerQuitChordProvider: @escaping @MainActor () -> ControllerQuitChord = { .none },
        customControllerChordProvider: @escaping @MainActor () -> Set<ControllerButton> = { [] },
        onBackgroundedChanged: (@MainActor (Bool) -> Void)? = nil,
        onMiniPlayerChanged: (@MainActor (Bool) -> Void)? = nil,
        // Esc or the quit chord before the stream is live: the caller's cancel.
        onCancelConnect: (@MainActor () -> Void)? = nil
    ) async throws -> AsyncStream<StreamEvent> {
        let options = StreamSetupOptions(config: config, negotiatedBitrateKbps: config.bitrateKbps,
            initialStatsOverlay: initialStatsOverlay, initialStatsCorner: initialStatsCorner,
            quitHotkeyProvider: quitHotkeyProvider, statsHotkeyProvider: statsHotkeyProvider,
            bookmarkHotkeyProvider: bookmarkHotkeyProvider, releasePointerHotkeyProvider: releasePointerHotkeyProvider,
            releaseInputHotkeyProvider: releaseInputHotkeyProvider, miniPlayerHotkeyProvider: miniPlayerHotkeyProvider,
            controllerQuitChordProvider: controllerQuitChordProvider,
            customControllerChordProvider: customControllerChordProvider, onBackgroundedChanged: onBackgroundedChanged,
            onMiniPlayerChanged: onMiniPlayerChanged, onCancelConnect: onCancelConnect)
        guard let stream = try await start(server: server, request: config.request, appID: appID,
            makeSampler: {
                #if DEBUG
                if ProcessInfo.processInfo.environment["GLIMMER_JOURNEY_DIRECTORY"] != nil {
                    return RttSampler(host: "pc.invalid", port: 0, maxAttempts: 0)
                }
                #endif
                return MacStreamPath.makeSampler(host: server.address, port: UInt16(server.httpsPort))
            },
            prepare: { [self] negotiated in
                let setup = buildStreamSubsystems(options)
                setup.1.controllerLayouts = MacControllerLayouts(forwarder: setup.1,
                    scope: .game(pcID: server.uniqueId, appID: UInt32(clamping: appID)))
                setup.1.onControllerMenu = { [weak input = setup.1, weak window = setup.0, weak self] slot in
                    guard let input, let window, input.streamControls == nil,
                          let token = input.controllerToken(slot: slot) else { return }
                    MacStreamControls(input: input, stream: window, slot: slot, token: token,
                                      appName: config.appName, pcName: server.serverName) {
                        Task { [weak self] in
                            guard let self, let network = await self.network else { return }
                            await self.disconnectLeavingGameRunning()
                            do { try await Self.quitRunningApp(network: network, expectedAppID: appID) } catch {
                                let alert = NSAlert()
                                alert.messageText = "Couldn't quit the game on \(server.serverName)."
                                alert.informativeText = "Check the PC, then try again."
                                alert.runModal()
                            }
                        }
                    }.show()
                }
                #if DEBUG
                JourneyMacPC.active?.prepare(setup)
                #endif
                setup.2.setNegotiatedBitrateKbps(negotiated)
                let prepared = Self.prepareMacMedia(setup, session: self,
                    statsRowsProvider: statsRowsProvider, statsThresholdsProvider: statsThresholdsProvider)
                prepared.presentation.displayMode = config.displayMode.rawValue
                return prepared
            }) else { throw CancellationError() }
        return stream
    }
}
