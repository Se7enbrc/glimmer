// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Network
import SwiftUI

enum PCAddress {
    static func parse(_ text: String) -> String? {
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }
        if IPv4Address(value) != nil || IPv6Address(value) != nil { return value }
        guard value.count <= 253, let parts = URLComponents(string: "http://" + value),
              parts.host != nil, parts.user == nil, parts.password == nil, parts.port == nil,
              parts.path.isEmpty, parts.query == nil, parts.fragment == nil,
              !value.allSatisfy({ $0.isNumber || $0 == "." }) else { return nil }
        let labels = value.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ label in
            label.count <= 63 && label.range(of: "^[A-Za-z0-9](?:[A-Za-z0-9-]*[A-Za-z0-9])?$",
                                             options: .regularExpression) != nil
        }) else { return nil }
        return value.lowercased()
    }
}

@MainActor
struct AddPCView: View {
    let connect: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @FocusState private var addressFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("IP address or hostname", text: $address)
                        .textContentType(.URL).keyboardType(.URL)
                        .textInputAutocapitalization(.never).autocorrectionDisabled()
                        .focused($addressFocused).submitLabel(.go)
                        .onSubmit(submit)
                } footer: {
                    Text("Enter the PC's address without a scheme, port or path.")
                }
            }
            .navigationTitle("Add PC")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", role: .cancel) { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Connect", action: submit).disabled(PCAddress.parse(address) == nil)
                }
            }
            .onAppear { addressFocused = true }
        }
    }

    private func submit() {
        guard let parsed = PCAddress.parse(address) else { return }
        connect(parsed)
        dismiss()
    }
}
