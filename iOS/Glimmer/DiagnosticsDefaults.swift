// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import StoreKit

@MainActor
enum DiagnosticsDefaults {
    @discardableResult
    static func register(
        defaults: UserDefaults = .standard,
        development: Bool = AppDisplayActivity.developmentBuild,
        environment: @escaping @MainActor () async throws -> AppStore.Environment? = installedEnvironment
    ) -> Task<Void, Never> {
        defaults.register(defaults: ["telemetryEnabled": development])
        // Resolve once without delaying launch. Registration never replaces a saved choice.
        return Task {
            guard !development else { return }
            let installed = try? await environment()
            defaults.register(defaults: ["telemetryEnabled": installed == .sandbox || installed == .xcode])
        }
    }

    private static func installedEnvironment() async throws -> AppStore.Environment? {
        guard case let .verified(transaction) = try await AppTransaction.shared else { return nil }
        return transaction.environment
    }
}
