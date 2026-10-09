import Foundation
import Network
import Testing
@testable import Glimmer

@MainActor
struct TelemetryGateTests {
    private func withFreshDefaults(_ body: (UserDefaults) throws -> Void) throws {
        let name = "TelemetryGateTests." + UUID().uuidString
        let defaults = try #require(UserDefaults(suiteName: name))
        defer { defaults.removePersistentDomain(forName: name) }
        GlimmerApp.registerDefaults(defaults: defaults)
        try body(defaults)
    }

    @Test func freshDefaultsKeepTelemetryOffAndDiagnosticsHidden() throws {
        try withFreshDefaults { defaults in
            #expect(!TelemetryGate.isEnabled(defaults: defaults, environmentValue: nil))
            #expect(!TelemetryGate.diagnosticsVisible(defaults: defaults))
            #expect(!TelemetryGate.listensOnLAN(defaults: defaults))
            let parameters = TelemetryExporter.listenerParameters(listenOnLAN: TelemetryGate.listensOnLAN(defaults: defaults))
            #expect(parameters.requiredInterfaceType == .loopback)
        }
    }

    @Test(arguments: [nil, "", "0", "true", "yes", "1"] as [String?])
    func onlyTheExplicitEnvironmentValueEnablesTelemetry(value: String?) throws {
        try withFreshDefaults { defaults in
            #expect(TelemetryGate.isEnabled(defaults: defaults, environmentValue: value) == (value == "1"))
            #expect(!TelemetryGate.diagnosticsVisible(defaults: defaults))
            #expect(!TelemetryGate.listensOnLAN(defaults: defaults))
        }
    }

    @Test(arguments: [nil, "0", "1"] as [String?])
    func preferenceOptInDoesNotRequireEnvironment(value: String?) throws {
        try withFreshDefaults { defaults in
            defaults.set(true, forKey: "telemetryEnabled")
            #expect(TelemetryGate.isEnabled(defaults: defaults, environmentValue: value))
            #expect(!TelemetryGate.diagnosticsVisible(defaults: defaults))
            #expect(!TelemetryGate.listensOnLAN(defaults: defaults))
        }
    }

    @Test func revealingDiagnosticsDoesNotEnableCollectionOrLAN() throws {
        try withFreshDefaults { defaults in
            defaults.set(true, forKey: "showDiagnostics")
            #expect(TelemetryGate.diagnosticsVisible(defaults: defaults))
            #expect(!TelemetryGate.isEnabled(defaults: defaults, environmentValue: nil))
            #expect(!TelemetryGate.listensOnLAN(defaults: defaults))
        }
    }

    @Test func lanBindingRequiresASeparatePreference() throws {
        try withFreshDefaults { defaults in
            defaults.set(true, forKey: "telemetryEnabled")
            #expect(!TelemetryGate.listensOnLAN(defaults: defaults))
            defaults.set(true, forKey: TelemetryExporter.lanBindDefaultsKey)
            #expect(TelemetryGate.listensOnLAN(defaults: defaults))
            let parameters = TelemetryExporter.listenerParameters(listenOnLAN: TelemetryGate.listensOnLAN(defaults: defaults))
            #expect(parameters.requiredInterfaceType != .loopback)
            defaults.set(false, forKey: "telemetryEnabled")
            #expect(!TelemetryGate.isEnabled(defaults: defaults, environmentValue: nil))
            #expect(!TelemetryGate.diagnosticsVisible(defaults: defaults))
        }
    }
}
