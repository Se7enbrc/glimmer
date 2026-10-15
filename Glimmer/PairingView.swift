// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import SwiftUI

@MainActor
struct PairingView: View {
    let prompt: LauncherModel.PairingPrompt
    let cancel: () -> Void

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 24) {
                    Text("Enter this PIN in Sunshine on \(prompt.name).")
                        .multilineTextAlignment(.center)
                    Text(prompt.pin).font(.largeTitle.monospacedDigit()).textSelection(.disabled)
                        .accessibilityLabel("Pairing PIN")
                        .accessibilityValue(prompt.pin.map(String.init).joined(separator: " "))
                    ProgressView("Waiting for the PC…")
                }
                .frame(maxWidth: .infinity)
                .padding()
            }
            .navigationTitle("Pair with the PC")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", role: .cancel) { cancel() }
                }
            }
        }
        .interactiveDismissDisabled()
    }
}
