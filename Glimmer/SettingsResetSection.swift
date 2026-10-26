// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import SwiftUI

struct SettingsResetSection: View {
    var enabled = true
    let reset: @MainActor (Bool) async throws -> Void
    @State private var presented = false

    var body: some View {
        Section {
            Button("Reset to defaults…") { presented = true }
                .disabled(!enabled)
        } footer: {
            if !enabled { Text("Stop streaming before resetting settings.") }
        }
        .sheet(isPresented: $presented) { SettingsResetConfirmation(reset: reset) }
    }
}

struct SettingsResetConfirmation: View {
    let reset: @MainActor (Bool) async throws -> Void
    @State private var includeGames = false
    @State private var saving = false
    @State private var failure: String?
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Reset stream quality, input and shortcuts, controller layouts, "
                         + "touch control layouts and opacity, and app preferences.")
                    Toggle("Also reset per-game controller layouts", isOn: $includeGames)
                } footer: {
                    Text("Paired PCs, pairing identity, your app library and diagnostics captures are kept. "
                         + "This can't be undone.")
                }
                if let failure { Section { Text(failure).foregroundStyle(.red) } }
            }
            .formStyle(.grouped)
            .navigationTitle("Reset to defaults?")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }.disabled(saving)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Reset", role: .destructive) { performReset() }.disabled(saving)
                }
            }
        }
        .interactiveDismissDisabled(saving)
        #if os(macOS)
        .frame(width: 480, height: 320)
        #endif
    }

    private func performReset() {
        saving = true
        Task {
            do {
                try await reset(includeGames)
                dismiss()
            } catch {
                failure = "Couldn't reset settings. Try again."
                saving = false
            }
        }
    }
}
