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
    var isRefreshing: Bool { timer != nil }

    init(surface: StreamSurface, defaults: UserDefaults = PersistentStorage.defaults,
         snapshot: @escaping () -> StreamStatsSnapshot, collection: @escaping (Bool) -> Void,
         videoSize: @escaping () -> CGSize, backdrop: @escaping (CGRect) -> Double?) {
        self.surface = surface
        self.defaults = defaults
        self.snapshot = snapshot
        self.collection = collection
        self.videoSize = videoSize
        self.backdrop = backdrop
        overlay.displayView = surface
        overlay.corner = .persisted(defaults: defaults)
        overlay.attach(to: surface.displayLayer)
        surface.stats = self
    }

    func setVisible(_ visible: Bool) {
        guard visible != isRefreshing else { return }
        collection(visible)
        overlay.setVisible(visible)
        if visible {
            tick()
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
        if let luminance = backdrop(overlay.backdropSampleRect) { overlay.updateBackdropLuminance(luminance) }
    }

    isolated deinit {
        timer?.invalidate()
        collection(false)
        _ = backdrop(.zero)
        overlay.layer.removeFromSuperlayer()
    }
}
