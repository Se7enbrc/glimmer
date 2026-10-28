// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import SwiftUI

struct ControllerSettingsRow: View {
    let title: String
    var value: String = ""
    var symbol: String?
    var role: ButtonRole?
    let action: () -> Void
    // Grouped Mac forms add 13 more points around button rows than iOS forms.
    #if os(macOS)
    @ScaledMetric(relativeTo: .body) private var rowHeight = 31.0
    #else
    @ScaledMetric(relativeTo: .body) private var rowHeight = 44.0
    #endif

    var body: some View {
        Button(role: role, action: action) {
            LabeledContent {
                Text(value).foregroundStyle(Color.secondary)
            } label: {
                if let symbol { Label(title, systemImage: symbol) } else { Text(title) }
            }
            .foregroundStyle(role == .destructive ? Color.red : Color.accentColor)
            .frame(minHeight: rowHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .accessibilityInputLabels([title])
    }
}

private struct ControllerSettingsForm: ViewModifier {
    func body(content: Content) -> some View {
        content.formStyle(.grouped)
            .font(.body)
            .buttonStyle(.borderless)
            .pickerStyle(.menu)
            .toggleStyle(.switch)
    }
}

private struct ControllerSettingsFootnote: ViewModifier {
    func body(content: Content) -> some View { content.font(.footnote) }
}

extension View {
    func controllerSettingsFootnote() -> some View { modifier(ControllerSettingsFootnote()) }
    func controllerSettingsForm() -> some View { modifier(ControllerSettingsForm()) }
}

struct ControllerSettingsPicker<Selection: Hashable, Choices: View>: View {
    let title: String
    let value: String
    @Binding var selection: Selection
    @ViewBuilder let choices: () -> Choices
    #if os(macOS)
    @ScaledMetric(relativeTo: .body) private var rowHeight = 31.0
    #else
    @ScaledMetric(relativeTo: .body) private var rowHeight = 44.0
    #endif

    var body: some View {
        #if os(macOS)
        Picker(title, selection: $selection, content: choices)
            .pickerStyle(.menu)
            .frame(minHeight: rowHeight)
            .accessibilityLabel(title)
            .accessibilityIdentifier("controller-settings-picker-\(title)")
            .accessibilityValue(value)
        #else
        Menu {
            Picker(title, selection: $selection, content: choices).pickerStyle(.inline).labelsHidden()
        } label: {
            LabeledContent {
                HStack(spacing: 4) {
                    Text(value)
                    Image(systemName: "chevron.up.chevron.down").font(.caption2)
                }.foregroundStyle(Color.accentColor)
            } label: { Text(title).foregroundStyle(.primary) }
                .frame(minHeight: rowHeight)
                .contentShape(.rect)
        }
        .buttonStyle(.plain).menuIndicator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .accessibilityLabel(title)
        .accessibilityValue(value)
        #endif
    }
}
