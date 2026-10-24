// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import StoreKit
import Testing
@testable import Glimmer

@MainActor
struct DiagnosticsDefaultsTests {
    private let suite = "io.ugfugl.Glimmer.diagnostics-tests.\(UUID().uuidString)"
    private let defaults: UserDefaults

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    @Test(arguments: [
        (AppStore.Environment.sandbox, true), (.production, false), (.xcode, true),
        (nil, false), (AppStore.Environment(rawValue: "unknown"), false)
    ] as [(AppStore.Environment?, Bool)])
    func environmentDefault(environment: AppStore.Environment?, expected: Bool) async {
        defer { defaults.removePersistentDomain(forName: suite) }
        let check = DiagnosticsDefaults.register(defaults: defaults, development: false) { environment }
        #expect(defaults.bool(forKey: "telemetryEnabled") == false)
        await check.value
        #expect(defaults.bool(forKey: "telemetryEnabled") == expected)
        #expect(defaults.persistentDomain(forName: suite)?["telemetryEnabled"] == nil)
    }

    @Test func developmentEnablesImmediatelyWithoutStoreKit() async {
        defer { defaults.removePersistentDomain(forName: suite) }
        let check = DiagnosticsDefaults.register(defaults: defaults, development: true) {
            Issue.record("Development builds should not need a StoreKit check.")
            throw CancellationError()
        }
        #expect(defaults.bool(forKey: "telemetryEnabled"))
        await check.value
        #expect(defaults.bool(forKey: "telemetryEnabled"))
    }

    @Test func failedCheckLeavesDiagnosticsOff() async {
        defer { defaults.removePersistentDomain(forName: suite) }
        await DiagnosticsDefaults.register(defaults: defaults, development: false) {
            throw CancellationError()
        }.value
        #expect(defaults.bool(forKey: "telemetryEnabled") == false)
        #expect(defaults.persistentDomain(forName: suite)?["telemetryEnabled"] == nil)
    }

    @Test(arguments: [false, true], [false, true])
    func savedChoiceSurvives(enabled: Bool, development: Bool) async {
        defer { defaults.removePersistentDomain(forName: suite) }
        defaults.set(enabled, forKey: "telemetryEnabled")
        let check = DiagnosticsDefaults.register(defaults: defaults, development: development) { .sandbox }
        #expect(defaults.bool(forKey: "telemetryEnabled") == enabled)
        await check.value
        #expect(defaults.bool(forKey: "telemetryEnabled") == enabled)
        #expect(defaults.persistentDomain(forName: suite)?["telemetryEnabled"] as? Bool == enabled)
    }

    @Test func choiceMadeDuringCheckSurvives() async {
        defer { defaults.removePersistentDomain(forName: suite) }
        let gate = StreamTestGate()
        let check = DiagnosticsDefaults.register(defaults: defaults, development: false) {
            await gate.wait()
            return .sandbox
        }
        await gate.waitUntilEntered()
        #expect(defaults.bool(forKey: "telemetryEnabled") == false)
        defaults.set(false, forKey: "telemetryEnabled")
        await gate.release()
        await check.value
        #expect(defaults.bool(forKey: "telemetryEnabled") == false)
        #expect(defaults.persistentDomain(forName: suite)?["telemetryEnabled"] as? Bool == false)
        defaults.removeObject(forKey: "telemetryEnabled")
        #expect(defaults.bool(forKey: "telemetryEnabled"))
    }
}
