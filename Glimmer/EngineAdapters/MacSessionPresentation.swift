// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import AppKit
import Foundation

extension SessionInputHooks {
    convenience init(_ input: InputForwarder) {
        self.init(setBackend: { input.setBackend($0) }, setReady: { input.setReady($0) },
            quiesce: { input.inputOwnershipLost(reason: "stream teardown") }, detach: { input.detach() },
            configure: {
                CruiseTraversal.configure(input, streamWidth: $0.width)
                input.streamPixelSize = CGSize(width: $0.width, height: $0.height)
            })
    }
}

extension SessionPresentation {
    convenience init(_ window: StreamWindow) {
        self.init()
        showRecovery = { text in
            if let text { window.reconnectBanner.setText(text) }
            window.reconnectBanner.setVisible(text != nil)
        }
        hideOverlay = { window.statsOverlay.setVisible(false) }
        close = { window.close() }
        waitForVisualClose = { await window.waitForVisualClose() }
        setCursorHidden = { window.setCursorHidden($0) }
        toggleMiniPlayer = { window.toggleMiniPlayer() }
        resume = {
            NSApp.activate()
            window.window.makeKeyAndOrderFront(nil)
            window.reengageForeground()
        }
        setStatsCorner = { if let corner = StatsOverlayCorner(rawValue: $0) { window.statsOverlay.corner = corner } }
    }
}

extension StreamSession {
    @MainActor static func prepareMacMedia(
        _ setup: (StreamWindow, InputForwarder, VideoDecoder), session: StreamSession,
        statsRowsProvider: @escaping @MainActor () -> Set<StatsRow.Kind>,
        statsThresholdsProvider: @escaping @MainActor () -> StatsThresholds) -> SessionMedia {
        let (window, input, decoder) = setup
        let presentation = SessionPresentation(window)
        if let firstFrame = decoder.onFirstDecodedFrame { presentation.firstFrame = { firstFrame() } }
        let stats = MacSessionStats(window: window, input: input, decoder: decoder,
            clock: session.clock, rows: statsRowsProvider, thresholds: statsThresholdsProvider)
        presentation.startStats = { stats.start() }
        presentation.stopStats = { stats.stop() }
        presentation.rendererProbe = { [weak decoder, weak window] in
            guard let decoder, let renderer = decoder.sampleBufferRenderer else { return nil }
            let identity = ObjectIdentifier(renderer)
            return RendererPerformanceSource(
                renderer, presentation: decoder.rendererPresentationState) { [weak decoder, weak window] transition in
                Task { @MainActor in
                    guard let window, let decoder, !window.didClose,
                          ObjectIdentifier(window.displayLayer.sampleBufferRenderer) == identity else { return }
                    window.logRendererTransition(transition, hdrInput: decoder.isHDRActive)
                }
            }
        }
        input.onQuitHotkey = { [weak session] in Task { await session?.stop() } }
        window.onCloseRequested = { [weak session] in Task { await session?.stop() } }
        input.onMiniPlayerHotkey = { [weak window] in window?.toggleMiniPlayer() }
        input.onStatsHotkey = { [weak decoder] in decoder?.toggleStatsOverlay() }
        input.onBookmarkHotkey = { [weak session] in Task { await session?.recordTelemetryBookmark() } }
        return SessionMedia(presentation: presentation, input: SessionInputHooks(input), video: decoder)
    }

    func setCursorHidden(_ hidden: Bool) async { await presentation?.setCursorHidden(hidden) }
    func toggleMiniPlayer() async {
        guard !isTearingDown else { return }
        await presentation?.toggleMiniPlayer()
    }
    func resumeWindow() async {
        guard !isTearingDown else { return }
        await presentation?.resume()
    }
    func setStatsOverlayCorner(_ corner: StatsOverlayCorner) async { await presentation?.setStatsCorner(corner.rawValue) }
}
