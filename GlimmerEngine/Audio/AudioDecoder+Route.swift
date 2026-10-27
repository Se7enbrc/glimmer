// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

extension AudioDecoder {
    package func requestOutputDiagnostic(bookmark: UInt64) {
        beginGraphChange()
        defer { endGraphChange() }
        queueOutputDiagnosticLocked(bookmark: bookmark)
    }

    /// Caller holds stateLock. One queued capture coalesces transitions and bookmark ranges.
    func queueOutputDiagnosticLocked(bookmark: UInt64? = nil) {
        #if os(macOS)
        guard TelemetryGate.isEnabled, !isShutdown, inputFormat != nil,
              outputDiagnosticRequests.request(bookmark: bookmark) else { return }
        enqueueOutputDiagnostic(generation: engineRestartGeneration)
        #endif
    }

    #if os(macOS)
    private func enqueueOutputDiagnostic(generation: UInt64) {
        routeListenerQueue.async { [weak self] in self?.captureOutputDiagnostic(generation: generation) }
    }

    private func captureOutputDiagnostic(generation: UInt64) {
        beginGraphChange()
        guard generation == engineRestartGeneration else { endGraphChange(); return }
        guard TelemetryGate.isEnabled, !isShutdown, inputFormat != nil else {
            outputDiagnosticRequests = AudioOutputDiagnosticRequests()
            endGraphChange()
            return
        }
        endGraphChange()
        let readVolume = platform.captureVolume()
        beginGraphChange()
        guard generation == engineRestartGeneration, !isShutdown else { endGraphChange(); return }
        let bookmarks = outputDiagnosticRequests.take()
        var snapshot = AudioOutputDiagnostic(
            playerGain: 1, mainGain: outputMuted ? 0 : 1,
            spatialGain: halOutput?.spatial == true ? 1 : nil, sampleRate: halOutput?.sampleRate ?? 0,
            channels: halOutput?.channels ?? 0, muted: outputMuted, running: engineRunning)
        endGraphChange()

        // HAL IPC never holds the decoder lock; a changed default invalidates its volume reading.
        let volume = readVolume()
        snapshot.halVolume = volume.volume
        snapshot.halMuted = volume.muted
        snapshot.routeChanged = volume.routeChanged

        beginGraphChange()
        defer { endGraphChange() }
        guard generation == engineRestartGeneration, !isShutdown else { return }
        if TelemetryGate.isEnabled {
            TelemetryExporter.recordLiveEvent(snapshot.fields(bookmarks: bookmarks))
        }
        if outputDiagnosticRequests.finish() { enqueueOutputDiagnostic(generation: generation) }
    }
    #endif
}

/// Constant storage regardless of request rate; a snapshot names every coalesced bookmark's range.
struct AudioOutputDiagnosticRequests {
    init() {}

    struct Bookmarks {
        var first: UInt64?
        var last: UInt64?
    }
    private var queued = false
    private var pending = false
    private var bookmarks = Bookmarks()

    mutating func request(bookmark: UInt64?) -> Bool {
        pending = true
        if let bookmark {
            bookmarks.first = min(bookmarks.first ?? bookmark, bookmark)
            bookmarks.last = max(bookmarks.last ?? bookmark, bookmark)
        }
        guard !queued else { return false }
        queued = true
        return true
    }

    mutating func take() -> Bookmarks {
        let result = bookmarks
        bookmarks = Bookmarks()
        pending = false
        return result
    }

    mutating func finish() -> Bool {
        queued = pending
        return pending
    }
}

/// Only numeric output state leaves this type; device identifiers remain local to the HAL read.
struct AudioOutputDiagnostic {
    var playerGain: Float
    var mainGain: Float
    var spatialGain: Float?
    var sampleRate: Double
    var channels: UInt32
    var muted: Bool
    var running: Bool
    var halVolume: Float?
    var halMuted: Bool?
    var routeChanged = false

    func fields(bookmarks: AudioOutputDiagnosticRequests.Bookmarks) -> [String] {
        #if os(macOS)
        var fields = ["\"event\":\"audio_output_state\"",
                      "\"reason\":\"\(bookmarks.last == nil ? "configuration" : "bookmark")\"",
                      "\"output_channels\":\(channels)", "\"stream_muted\":\(muted)",
                      "\"engine_running\":\(running)", "\"default_route_changed\":\(routeChanged)"]
        let numbers: [(String, Double?)] = [
            ("player_gain", Double(playerGain)), ("main_mixer_gain", Double(mainGain)),
            ("spatial_mixer_gain", spatialGain.map(Double.init)), ("output_rate_hz", sampleRate),
            ("hal_output_volume", routeChanged ? nil : halVolume.map(Double.init))]
        for (key, value) in numbers {
            if let value, value.isFinite { fields.append("\"\(key)\":\(value)") }
        }
        if !routeChanged, let halMuted { fields.append("\"hal_output_muted\":\(halMuted)") }
        if let first = bookmarks.first { fields.append("\"bookmark_first\":\(first)") }
        if let last = bookmarks.last { fields.append("\"bookmark_total\":\(last)") }
        return fields
        #else
        return []
        #endif
    }
}
