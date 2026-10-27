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
    @ScaledMetric(relativeTo: .body) private var textSize = 17.0

    func body(content: Content) -> some View {
        content.formStyle(.grouped)
            .font(.system(size: textSize))
            .buttonStyle(.borderless)
            .pickerStyle(.menu)
            .toggleStyle(.switch)
    }
}

private struct ControllerSettingsFootnote: ViewModifier {
    @ScaledMetric(relativeTo: .footnote) private var textSize = 13.0

    func body(content: Content) -> some View { content.font(.system(size: textSize)) }
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
    @ScaledMetric(relativeTo: .body) private var rowHeight = 44.0

    var body: some View {
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
    }
}
