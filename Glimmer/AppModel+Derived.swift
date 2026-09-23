//
//  AppModel+Derived.swift
//
//  Computed properties and small methods that read AppModel's own stored
//  state without holding any of their own. Split out of AppModel.swift to
//  leave headroom there under the file-length cap for new stored state.
//

import Foundation

extension AppModel {

    var pairingInFlight: Bool { pairingAttempt != nil }

    /// The row set the overlay renders, resolved against the current
    /// preset: custom mode reads `statsOverlayCustomRows`, the curated
    /// presets resolve to their static sets in `StatsOverlayDefaults`.
    var effectiveStatsRows: Set<StatsRow.Kind> {
        switch statsOverlayPreset {
        case .minimal:  return StatsOverlayDefaults.minimalRows
        case .micro:    return StatsOverlayDefaults.microRows
        case .extended: return StatsOverlayDefaults.extendedRows
        case .custom:   return statsOverlayCustomRows
        }
    }

    /// Bring the stream window back from the background. Called by the
    /// launcher's "Back to stream" CTA when nativeStreamBackgrounded is true.
    public func resumeStreamWindow() {
        Task { [weak self] in
            await self?.nativeSession?.resumeWindow()
        }
    }
}
