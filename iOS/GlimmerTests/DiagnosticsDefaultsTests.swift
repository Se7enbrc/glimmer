// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
@testable import GlimmerEngine
import Testing
@testable import Glimmer

@MainActor
struct DiagnosticsDefaultsTests {
    @Test(arguments: [nil, false, true] as [Bool?])
    func savedPreferenceCannotGrantDiagnostics(saved: Bool?) throws {
        let suite = "io.ugfugl.Glimmer.diagnostics-tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        if let saved { defaults.set(saved, forKey: "telemetryEnabled") }
        DiagnosticsDefaults.register(defaults: defaults)
        #if GLIMMER_DIAGNOSTICS
        #expect(DiagnosticsAvailability.compiledIn)
        #expect(DiagnosticsAvailability.isEnabled(defaults: defaults) == (saved ?? true))
        #expect(DiagnosticsDefaults.directory != nil)
        #expect(defaults.bool(forKey: AdaptiveBandwidth.defaultsKey))
        #else
        #expect(DiagnosticsAvailability.compiledIn == false)
        #expect(DiagnosticsAvailability.isEnabled(defaults: defaults) == false)
        #expect(DiagnosticsDefaults.directory == nil)
        #expect(defaults.bool(forKey: AdaptiveBandwidth.defaultsKey) == false)
        for override in [nil, "1", "unknown"] as [String?] {
            #expect(TelemetryGate.isEnabled(defaults: defaults, environmentValue: override) == false)
        }
        #endif
        #expect(defaults.persistentDomain(forName: suite)?["telemetryEnabled"] as? Bool == saved)
    }

    #if !GLIMMER_DIAGNOSTICS
    @Test func productionLeavesPreviousFilesUntouchedEvenWithForcedEnable() throws {
        let directory = URL.temporaryDirectory.appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let previous = directory.appendingPathComponent("previous-session.log")
        let contents = Data("existing beta diagnostics".utf8)
        try contents.write(to: previous)
        let services = SessionServices.recording(directory: directory, enabled: true)
        services.startLog()
        services.stopLog()
        #expect(try Data(contentsOf: previous) == contents)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == [previous.lastPathComponent])
    }
    #endif

    @Test func controlMeasurementsSurviveBothFlavours() {
        let operational = TelemetryCounters.Counter(operational: true)
        let diagnostic = TelemetryCounters.Counter()
        operational.increment(by: 7)
        diagnostic.increment(by: 7)
        #expect(operational.value == 7)
        #if GLIMMER_DIAGNOSTICS
        #expect(diagnostic.value == 7)
        #else
        #expect(diagnostic.value == 0)
        #endif
        let stats = StatsCollector()
        #expect(stats.secondsSinceLastDecodedFrame().isInfinite)
        #expect(stats.secondsSinceLastPresent().isInfinite)
        stats.recordReceivedFrame(bytes: 128, frameNumber: 1)
        stats.recordDecodedFrame()
        stats.recordRendererEnqueue()
        #expect(stats.receivedBytesSnapshot() == (DiagnosticsAvailability.compiledIn ? 128 : 0))
        #expect(stats.secondsSinceLastDecodedFrame().isFinite)
        #expect(stats.secondsSinceLastPresent().isFinite)
        stats.resetForConnection()
        #expect(stats.receivedBytesSnapshot() == (DiagnosticsAvailability.compiledIn ? 128 : 0))
        #expect(stats.secondsSinceLastDecodedFrame().isInfinite)
        #expect(stats.secondsSinceLastPresent().isInfinite)
    }

    @Test func settingsMatchCompiledFlavour() {
        #if GLIMMER_DIAGNOSTICS
        #expect(GlimmerSettings.Page.allCases.map(\.rawValue).contains("diagnostics"))
        #else
        #expect(GlimmerSettings.Page.allCases.map(\.rawValue).contains("diagnostics") == false)
        #endif
    }
}
