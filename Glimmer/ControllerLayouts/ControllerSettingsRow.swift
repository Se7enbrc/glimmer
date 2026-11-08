// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import SwiftUI

struct ControllerSettingsRow: View {
    let title: String
    var value: String = ""
    var symbol: String?
    var role: ButtonRole?
    let action: () -> Void
    @Environment(\.streamControlsScale) private var streamScale
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
            .frame(minHeight: streamScale.map { 48 * $0 } ?? rowHeight)
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .controllerSettingsFocus(action: action)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .accessibilityInputLabels([title])
    }
}

private struct ControllerSettingsForm: ViewModifier {
    @Environment(\.streamControlsScale) private var scale
    func body(content: Content) -> some View {
        #if os(macOS)
        if let scale {
            content.formStyle(.grouped).streamFont(.title2, scale: scale)
                .buttonStyle(.borderless).pickerStyle(.menu).toggleStyle(.switch)
                .controlSize(.large).scrollContentBackground(.hidden)
        } else { standard(content) }
        #else
        standard(content)
        #endif
    }

    private func standard(_ content: Content) -> some View {
        content.formStyle(.grouped)
            .font(.body)
            .buttonStyle(.borderless)
            .pickerStyle(.menu)
            .toggleStyle(.switch)
    }
}

private struct ControllerSettingsFootnote: ViewModifier {
    @Environment(\.streamControlsScale) private var scale
    func body(content: Content) -> some View {
        #if os(macOS)
        if let scale { content.streamFont(.body, scale: scale) } else { content.font(.footnote) }
        #else
        content.font(.footnote)
        #endif
    }
}

private struct StreamControlsScaleKey: EnvironmentKey {
    static let defaultValue: CGFloat? = nil
}

extension EnvironmentValues {
    var streamControlsScale: CGFloat? {
        get { self[StreamControlsScaleKey.self] }
        set { self[StreamControlsScaleKey.self] = newValue }
    }
}

extension View {
    func controllerSettingsFootnote() -> some View { modifier(ControllerSettingsFootnote()) }
    func controllerSettingsForm() -> some View { modifier(ControllerSettingsForm()) }
}

struct ControllerSettingsNavigation<Content: View>: View {
    @ViewBuilder let content: () -> Content
    @Environment(\.streamControlsScale) private var scale

    var body: some View {
        #if os(macOS)
        if scale != nil { content() } else { NavigationStack { content() } }
        #else
        NavigationStack { content() }
        #endif
    }
}

private struct ControllerSettingsDestination<Item: Identifiable & Hashable, Destination: View>: ViewModifier {
    @Binding var item: Item?
    @ViewBuilder let destination: (Item) -> Destination
    @Environment(\.streamControlsScale) private var scale

    func body(content: Content) -> some View {
        #if os(macOS)
        if scale != nil { content.navigationDestination(item: $item, destination: destination) } else {
            content.sheet(item: $item, content: destination)
        }
        #else
        content.sheet(item: $item, content: destination)
        #endif
    }
}

private struct ControllerSettingsCaptureDestination<Destination: View>: ViewModifier {
    @Binding var presented: Bool
    @ViewBuilder let destination: () -> Destination
    @Environment(\.streamControlsScale) private var scale

    func body(content: Content) -> some View {
        #if os(macOS)
        if scale != nil { content.navigationDestination(isPresented: $presented, destination: destination) } else {
            content.sheet(isPresented: $presented, content: destination)
        }
        #else
        content.sheet(isPresented: $presented, content: destination)
        #endif
    }
}

extension View {
    func controllerSettingsDestination<Item: Identifiable & Hashable, Destination: View>(
        item: Binding<Item?>, @ViewBuilder destination: @escaping (Item) -> Destination
    ) -> some View { modifier(ControllerSettingsDestination(item: item, destination: destination)) }

    func controllerSettingsDestination<Destination: View>(
        isPresented: Binding<Bool>, @ViewBuilder destination: @escaping () -> Destination
    ) -> some View { modifier(ControllerSettingsCaptureDestination(presented: isPresented, destination: destination)) }
}

struct ControllerSettingsPicker<Selection: Hashable, Choices: View>: View {
    let title: String
    let value: String
    @Binding var selection: Selection
    @ViewBuilder let choices: () -> Choices
    @Environment(\.streamControlsScale) private var streamScale
    #if os(macOS)
    @State private var presented = false
    @ScaledMetric(relativeTo: .body) private var rowHeight = 31.0
    #else
    @ScaledMetric(relativeTo: .body) private var rowHeight = 44.0
    #endif

    var body: some View {
        #if os(macOS)
        Button { presented = true } label: { row }
            .buttonStyle(.plain)
            .controllerSettingsFocus { presented = true }
            .background {
                NativeControllerMenu(presented: $presented) {
                    Picker(title, selection: $selection, content: choices).pickerStyle(.inline).labelsHidden()
                }
            }
            .accessibilityLabel(title).accessibilityValue(value)
            .accessibilityIdentifier("controller-settings-picker-\(title)")
        #else
        Menu {
            Picker(title, selection: $selection, content: choices).pickerStyle(.inline).labelsHidden()
        } label: { row }
        .buttonStyle(.plain).menuIndicator(.hidden)
        .listRowInsets(EdgeInsets(top: 0, leading: 16, bottom: 0, trailing: 16))
        .accessibilityLabel(title).accessibilityValue(value)
        #endif
    }

    private var row: some View {
        LabeledContent {
            HStack(spacing: 4) {
                Text(value)
                Image(systemName: "chevron.up.chevron.down").font(.caption2)
            }.foregroundStyle(Color.accentColor)
        } label: { Text(title).foregroundStyle(.primary) }
            .frame(minHeight: streamScale.map { 48 * $0 } ?? rowHeight)
            .contentShape(.rect)
    }
}

private struct ControllerSettingsFocus: ViewModifier {
    let action: () -> Void
    @Environment(\.isEnabled) private var enabled
    #if os(macOS)
    @FocusState private var focused: Bool
    #endif

    func body(content: Content) -> some View {
        #if os(macOS)
        content.focusable(false).focusable(true, interactions: .edit).focused($focused)
            .onKeyPress(.space) {
                guard focused, enabled else { return .ignored }
                action()
                return .handled
            }
        #else
        content
        #endif
    }
}

extension View {
    func controllerSettingsFocus(action: @escaping () -> Void) -> some View {
        modifier(ControllerSettingsFocus(action: action))
    }
}

struct ControllerSettingsNavigationLink<Destination: View, Label: View>: View {
    @ViewBuilder let destination: () -> Destination
    @ViewBuilder let label: () -> Label
    @State private var presented = false
    @Environment(\.streamControlsScale) private var streamScale

    var body: some View {
        #if os(macOS)
        Button { presented = true } label: {
            HStack {
                label()
                Spacer()
                Image(systemName: "chevron.right").foregroundStyle(.tertiary).accessibilityHidden(true)
            }
            .contentShape(.rect)
            .frame(minHeight: streamScale.map { 48 * $0 })
        }
        .buttonStyle(.plain)
        .controllerSettingsFocus { presented = true }
        .navigationDestination(isPresented: $presented, destination: destination)
        #else
        NavigationLink(destination: destination, label: label)
        #endif
    }
}
