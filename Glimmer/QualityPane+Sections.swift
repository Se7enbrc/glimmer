// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI

/// Display owns everything about the picture; Network owns how much data it uses.
extension QualityPane {
    @ViewBuilder var displaySection: some View {
        @Bindable var model = model
        Section {
            // Only the presets live in this card: rows under the radios read as more presets.
            Picker("", selection: $model.qualityPreset) {
                ForEach(QualityPreset.allCases) { preset in
                    VStack(alignment: .leading) {
                        Text(presetTitle(preset)).fontWeight(.medium)
                        Text(preset.subtitle).font(.footnote).foregroundStyle(.secondary)
                    }
                    .tag(preset)
                }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } header: {
            Text("Display")
        }

        if model.qualityPreset == .custom { customSection }

        Section {
            Toggle("HDR", isOn: $model.streamHDR)
                .toggleStyle(.switch)
                .help("Sends a 10-bit high-dynamic-range stream when the PC and this display both support it. "
                    + "Off asks the PC for SDR.")
            if model.effectiveDisplayMode == .fullScreen {
                Picker("Full screen", selection: usesSpace) {
                    Text("Cover the screen").tag(false)
                    Text("Use a Space").tag(true)
                }
                .pickerStyle(.segmented)
                .help("Cover the screen fills the whole display. Use a Space opens the stream in its own macOS Space.")
            }
        } footer: {
            Text(displayFooter)
        }
    }

    @ViewBuilder var networkSection: some View {
        Section {
            Picker("Bandwidth", selection: bandwidth) {
                ForEach(BandwidthChoice.allCases) { Text($0.displayName).tag($0) }
            }
            .pickerStyle(.segmented)
            Toggle(isOn: Binding(get: { awdl.isRegistered }, set: { scheduleHelperToggle($0) })) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Smooth out Wi-Fi stutter").fontWeight(.medium)
                    Text("Pauses AirDrop and Continuity while you stream, so they can't take over the Wi-Fi "
                        + "and freeze the picture. They come back the moment you stop. Needs a one-time approval.")
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
            .accessibilityLabel("Smooth out Wi-Fi stutter")
            .help("Installs a small helper that pauses AirDrop's radio for each stream.")
            helperStatus
        } header: {
            Text("Network")
        } footer: {
            Text("Automatic starts at the most the connection can carry and steps down only while it struggles. "
                + "Maximum stays there. Saver uses less.")
        }
    }

    @ViewBuilder private var helperStatus: some View {
        if case .requiresApproval = awdl.state {
            HStack(spacing: 8) {
                Label("macOS needs you to approve the Glimmer network helper in Login Items.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote).foregroundStyle(.orange)
                Spacer()
                Button("Open Login Items") { awdl.openSystemSettings() }
            }
        }
        if case .unavailable(let why) = awdl.state {
            VStack(alignment: .leading, spacing: 4) {
                Label("Network helper unavailable: \(why)", systemImage: "xmark.octagon")
                    .font(.footnote).foregroundStyle(.red)
                if let url = awdl.recoveryDocURL {
                    Link("How to manage login items (Apple Support)", destination: url)
                        .font(.footnote)
                }
            }
        }
    }

    /// Native and Retina scaled name the size this display would actually send.
    private func presetTitle(_ preset: QualityPreset) -> String {
        guard preset != .custom else { return preset.displayName }
        let size = model.effectiveValuesForPreset(preset)
        return "\(preset.displayName) · \(size.width) × \(size.height)"
    }

    /// One choice on screen, two saved settings: a notched built-in display keeps its own,
    /// so a Space chosen for an external display never changes the laptop's.
    private var usesSpace: Binding<Bool> {
        Binding(
            get: { model.currentDisplayHasNotch ? !model.streamCoversNotch : model.streamUsesFullScreenSpace },
            set: { space in
                if model.currentDisplayHasNotch {
                    model.streamCoversNotch = !space
                } else {
                    model.streamUsesFullScreenSpace = space
                }
            })
    }

    private var bandwidth: Binding<BandwidthChoice> {
        Binding(
            get: { BandwidthChoice(bitrateMode: model.bitrateMode, adaptive: adaptiveBandwidth) },
            set: { choice in
                model.bitrateMode = choice.bitrateMode
                adaptiveBandwidth = choice.adaptive
            })
    }

    private var displayFooter: String {
        var lines = ["HDR needs a PC and display that both support it."]
        if model.effectiveDisplayMode == .fullScreen {
            if model.currentDisplayHasNotch {
                lines.append("Use a Space keeps the picture below the camera.")
            }
            lines.append("macOS may turn on Game Mode; change it in Game Overlay › Settings › Game Mode.")
        }
        lines.append("Changes apply to the next stream.")
        return lines.joined(separator: " ")
    }
}
