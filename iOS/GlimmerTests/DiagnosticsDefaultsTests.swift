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
        StreamDefaults.register(defaults: defaults)
        #expect(DiagnosticsAvailability.compiledIn == false)
        #expect(DiagnosticsAvailability.isEnabled(defaults: defaults) == false)
        #if GLIMMER_DIAGNOSTICS
        #expect(defaults.bool(forKey: AdaptiveBandwidth.defaultsKey))
        #else
        #expect(defaults.bool(forKey: AdaptiveBandwidth.defaultsKey) == false)
        #endif
        for override in [nil, "1", "unknown"] as [String?] {
            #expect(TelemetryGate.isEnabled(defaults: defaults, environmentValue: override) == false)
        }
        #expect(defaults.persistentDomain(forName: suite)?["telemetryEnabled"] as? Bool == saved)
    }

    @Test func bothFlavoursLeavePreviousFilesUntouchedEvenWithForcedEnable() throws {
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

    @Test func controlMeasurementsSurviveBothFlavours() {
        let operational = TelemetryCounters.Counter(operational: true)
        let diagnostic = TelemetryCounters.Counter()
        operational.increment(by: 7)
        diagnostic.increment(by: 7)
        #expect(operational.value == 7)
        #expect(diagnostic.value == 0)
        let stats = StatsCollector()
        #expect(stats.secondsSinceLastDecodedFrame().isInfinite)
        #expect(stats.secondsSinceLastPresent().isInfinite)
        stats.recordReceivedFrame(bytes: 128, frameNumber: 1)
        stats.recordDecodedFrame()
        stats.recordRendererEnqueue()
        // The bandwidth policy reads received bytes and presentation times in both flavours.
        #expect(stats.receivedBytesSnapshot() == 128)
        #expect(stats.presentationTimes.last != nil)
        #expect(stats.secondsSinceLastDecodedFrame().isFinite)
        #expect(stats.secondsSinceLastPresent().isFinite)
        stats.resetForConnection()
        #expect(stats.receivedBytesSnapshot() == 128)
        #expect(stats.presentationTimes.last == nil)
        #expect(stats.secondsSinceLastDecodedFrame().isInfinite)
        #expect(stats.secondsSinceLastPresent().isInfinite)
    }

    @Test func adaptiveMeasurementsRemainInMemoryWithoutARecorder() {
        let measurements = ReceivePolicyMeasurements()
        for delay in [0.2, 0.4, 0.4, 3.0] { measurements.observeDelay(delay) }
        for jitter in Array(repeating: 0.3, count: 19) + [6] { measurements.observeFrameJitter(jitter) }
        let window = measurements.takeWindow()
        #expect(window.queueDelayP50Ms == 0.5 && window.jitterP95Ms == 0.5)
        #expect(measurements.takeWindow() == ReceivePolicyWindow())
    }

    @Test func settingsKeepAdaptiveQualityWithoutRecording() {
        #expect(GlimmerSettings.Page.allCases.map(\.rawValue).contains("diagnostics") == false)
        #expect(GlimmerSettings.Page.allCases.map(\.rawValue).contains("connection"))
    }
}

struct PersistentStorageTests {
    @Test func existingIdentitySurvivesResetPreferences() async throws {
        let suite = "identity-preservation-" + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: suite))
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: root)
        }
        let first = IdentityManager(defaultsSuite: suite, supportBase: root, protectedDataAvailable: { true })
        let originalID = try await first.uniqueID()
        let certificate = root.appendingPathComponent("Glimmer/Identity/client-cert.pem")
        let originalCertificate = try Data(contentsOf: certificate)
        defaults.removePersistentDomain(forName: suite)
        let second = IdentityManager(defaultsSuite: suite, supportBase: root, protectedDataAvailable: { true })
        #expect(try await second.uniqueID() == originalID)
        #expect(try Data(contentsOf: certificate) == originalCertificate)
    }

    @Test func testProcessCannotResolveInstallationStorage() throws {
        let root = try #require(PersistentStorage.testRoot)
        #expect(PersistentStorage.isTesting)
        let paths = [PersistentStorage.applicationSupport, PersistentStorage.caches,
                     PersistentStorage.logs, PersistentStorage.home,
                     PersistentStorage.supportRoot().appendingPathComponent("Glimmer/Identity"),
                     PersistentStorage.supportRoot().appendingPathComponent("Glimmer/PinnedHosts"),
                     PersistentStorage.supportRoot().appendingPathComponent("Glimmer/Covers")]
        for path in paths {
            #expect(path.path == root.path || path.path.hasPrefix(root.path + "/"))
        }
        #expect(PersistentStorage.defaults !== UserDefaults.standard)
    }
}
