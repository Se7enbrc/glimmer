// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GameController
import GlimmerEngine
import os
import UIKit

@MainActor
final class StreamStats {
    let overlay = StatsOverlayLayer()
    private weak var surface: StreamSurface?
    private var timer: Timer?
    private let snapshot: () -> StreamStatsSnapshot
    private let collection: (Bool) -> Void
    private let backdrop: (CGRect) -> Double?
    private let videoSize: () -> CGSize
    private let defaults: UserDefaults
    private let chromeSampling: (Bool) -> Void
    private var chromeVisible = false
    private var lastTouchArea: CGRect?
    private var lastTouchObstacles: [CGRect] = []
    private var lastContent = CGSize.zero
    private var requested = false
    private var crowdedByMenu = false
    var isRefreshing: Bool { timer != nil }

    init(surface: StreamSurface, defaults: UserDefaults = PersistentStorage.defaults,
         snapshot: @escaping () -> StreamStatsSnapshot, collection: @escaping (Bool) -> Void,
         videoSize: @escaping () -> CGSize, backdrop: @escaping (CGRect) -> Double?,
         chromeSampling: @escaping (Bool) -> Void = { _ in },
         observeBackdrop: (@escaping @Sendable (Double) -> Void) -> Void = { _ in }) {
        self.surface = surface
        self.defaults = defaults
        self.snapshot = snapshot
        self.collection = collection
        self.videoSize = videoSize
        self.backdrop = backdrop
        self.chromeSampling = chromeSampling
        overlay.displayView = surface
        overlay.corner = .persisted(defaults: defaults)
        overlay.attach(to: surface.displayLayer)
        surface.stats = self
        surface.overlayAppearance.layoutChanged = { [weak self] in self?.layout() }
        // Readings arrive on the present path; only an ink flip hops to the main actor.
        let ink = ChromeInk()
        observeBackdrop { [weak self] luminance in
            guard ink.flips(luminance) else { return }
            Task { @MainActor [weak self] in self?.surface?.overlayAppearance.update(luminance: luminance) }
        }
    }

    func setVisible(_ visible: Bool) {
        requested = visible
        applyVisibility()
    }

    // The open menu wins when the space beside it cannot hold the HUD legibly; stats return when it closes.
    private func applyVisibility() {
        let visible = requested && !crowdedByMenu
        guard visible != overlay.isVisible else { return }
        collection(visible)
        overlay.setVisible(visible)
        refreshTimer()
    }

    // Chrome alone needs no timer: the present path reports brightness and flips arrive by callback.
    func setChromeVisible(_ visible: Bool) {
        guard visible != chromeVisible else { return }
        chromeVisible = visible
        chromeSampling(visible)
        refreshTimer()
    }

    private var chromeRect: CGRect {
        Self.chromeSampleRect(view: surface?.bounds.size ?? .zero, video: videoSize())
    }

    private func refreshTimer() {
        if !overlay.isVisible { _ = backdrop(chromeVisible ? chromeRect : .zero) }
        if overlay.isVisible {
            tick()
            guard timer == nil else { return }
            let timer = Timer(timeInterval: 0.25, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.tick() }
            }
            timer.tolerance = 0.025
            self.timer = timer
            RunLoop.main.add(timer, forMode: .common)
        } else {
            timer?.invalidate()
            timer = nil
        }
    }

    func layout() {
        guard let surface else { return }
        if overlay.layer.superlayer !== surface.displayLayer { overlay.attach(to: surface.displayLayer) }
        if chromeVisible && !overlay.isVisible { _ = backdrop(chromeRect) }
        let touchControls = surface.overlayAppearance.touchObstacles
        let obstacles = touchControls + [surface.overlayAppearance.noticeFrame, surface.overlayAppearance.menuFrame]
            .compactMap { $0 }
        let area = surface.bounds.inset(by: StatsOverlayLayer.overlayInsets(for: surface))
        let content = overlay.layer.bounds.size
        if lastTouchArea != area || lastTouchObstacles != obstacles || lastContent != content {
            lastTouchArea = area
            lastTouchObstacles = obstacles
            lastContent = content
            overlay.compactRows = !obstacles.isEmpty && surface.bounds.height < 500
            // Seek a gap that holds the HUD at full size, so its text never shrinks below the system size.
            let scale = StatsOverlayLayer.viewportScale(in: area.size)
            let margin: CGFloat = overlay.compactRows ? 16 : 32
            let target = content.width > 0
                ? CGSize(width: content.width * scale + margin, height: content.height * scale + margin) : nil
            let clear = Self.clearStatsArea(in: area, avoiding: obstacles, corner: overlay.corner, target: target)
            overlay.placementBounds = obstacles.isEmpty ? nil
                : CGRect(x: clear.minX, y: surface.bounds.maxY - clear.maxY, width: clear.width, height: clear.height)
            let needed = target ?? CGSize(width: 220, height: 90)
            crowdedByMenu = surface.overlayAppearance.menuFrame != nil
                && min(clear.width / needed.width, clear.height / needed.height) < 0.8
        }
        overlay.layoutInHost(surface.displayLayer)
        applyVisibility()
    }

    func tick() {
        if overlay.isVisible {
            updateStats()
            if overlay.layer.bounds.size != lastContent { layout() }
        }
        // Share one sample: chrome follows the HUD's local reading while the HUD is up.
        guard overlay.isVisible, let luminance = backdrop(overlay.backdropSampleRect) else { return }
        overlay.updateBackdropLuminance(luminance)
    }

    static func chromeSampleRect(view: CGSize, video: CGSize) -> CGRect {
        guard view.width > 0, view.height > 0, video.width > 0, video.height > 0 else { return .zero }
        let scale = max(view.width / video.width, view.height / video.height)
        let width = min(1, view.width / (video.width * scale))
        let height = min(1, view.height / (video.height * scale))
        return CGRect(x: (1 - width) / 2, y: (1 - height) / 2, width: width, height: height)
    }

    private func updateStats() {
        var snapshot = snapshot()
        let preset = defaults.string(forKey: "statsOverlayPreset").flatMap(StatsOverlayPreset.init) ?? .minimal
        let rows: Set<StatsRow.Kind>
        switch preset {
        case .minimal: rows = StatsOverlayDefaults.minimalRows
        case .micro: rows = StatsOverlayDefaults.microRows
        case .extended: rows = StatsOverlayDefaults.extendedRows
        case .custom:
            rows = defaults.stringArray(forKey: "statsOverlayCustomRows")
                .map { Set($0.compactMap(StatsRow.Kind.init)) } ?? StatsOverlayDefaults.initialCustomRows
        }
        if rows.contains(.controllerBattery),
           let battery = GCController.controllers().compactMap(\.battery).first, battery.batteryLevel >= 0 {
            snapshot.controllerBatteryPercent = Int((battery.batteryLevel * 100).rounded())
            snapshot.controllerBatteryCharging = battery.batteryState == .charging
        }
        let thresholds = defaults.data(forKey: "statsThresholds")
            .flatMap { try? JSONDecoder().decode(StatsThresholds.self, from: $0) } ?? .default
        overlay.videoSize = videoSize()
        overlay.update(snapshot: snapshot, enabled: rows.subtracting([.macCpu, .macRam, .macBattery]),
                       targetFps: snapshot.configuredFps ?? 60, thresholds: thresholds)
    }

    isolated deinit {
        timer?.invalidate()
        collection(false)
        chromeSampling(false)
        _ = backdrop(.zero)
        overlay.layer.removeFromSuperlayer()
    }
}

/// Applies the overlay hysteresis off the main actor so steady scenes cost no main-thread work.
final class ChromeInk: Sendable {
    private let dark = OSAllocatedUnfairLock<Bool?>(initialState: nil)

    func flips(_ luminance: Double) -> Bool {
        dark.withLock { current in
            let next = StatsOverlayLayer.shouldUseDarkInk(luminance: luminance, currentlyDark: current ?? false)
            defer { current = next }
            return current != next
        }
    }
}
