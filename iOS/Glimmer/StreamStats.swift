// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GameController
import GlimmerEngine
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
    var isRefreshing: Bool { timer != nil }

    init(surface: StreamSurface, defaults: UserDefaults = PersistentStorage.defaults,
         snapshot: @escaping () -> StreamStatsSnapshot, collection: @escaping (Bool) -> Void,
         videoSize: @escaping () -> CGSize, backdrop: @escaping (CGRect) -> Double?,
         chromeSampling: @escaping (Bool) -> Void = { _ in }) {
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
    }

    func setVisible(_ visible: Bool) {
        guard visible != overlay.isVisible else { return }
        collection(visible)
        overlay.setVisible(visible)
        refreshTimer()
    }

    func setChromeVisible(_ visible: Bool) {
        guard visible != chromeVisible else { return }
        chromeVisible = visible
        chromeSampling(visible)
        refreshTimer()
    }

    private func refreshTimer() {
        if overlay.isVisible || chromeVisible {
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
            _ = backdrop(.zero)
        }
    }

    func layout() {
        guard let surface else { return }
        if overlay.layer.superlayer !== surface.displayLayer { overlay.attach(to: surface.displayLayer) }
        overlay.layoutInHost(surface.displayLayer)
    }

    func tick() {
        if overlay.isVisible { updateStats() }
        // Share one sample: preserve the HUD's local contrast when it is visible.
        let rect = overlay.isVisible ? overlay.backdropSampleRect
            : Self.chromeSampleRect(view: surface?.bounds.size ?? .zero, video: videoSize())
        if let luminance = backdrop(rect) {
            if overlay.isVisible { overlay.updateBackdropLuminance(luminance) }
            if chromeVisible { surface?.overlayAppearance.update(luminance: luminance) }
        }
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
