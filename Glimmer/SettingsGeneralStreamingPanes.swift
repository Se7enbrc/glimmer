// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

//
//  SettingsGeneralStreamingPanes.swift
//
//  The General and Quality settings panes (+ their resolution/stats helpers),
//  split out of SettingsView.swift. SettingsRoot composes them across files, so
//  the pane types are internal. (Filename keeps the pane's pre-rename
//  "Streaming" spelling - renaming the file means touching the pbxproj for
//  zero behavioural gain.) `LoginItemManager`, the registration plumbing behind
//  the General pane's launch toggles, lives in
//  SettingsGeneralStreamingPanes+LoginItem.swift.
//

import AppKit
import os
import ServiceManagement
import SwiftUI

// MARK: - General

struct GeneralPane: View {
    @Environment(AppModel.self) private var model
    @AppStorage("launchAtLogin") private var launchAtLogin: Bool = false
    @AppStorage("launchMinimized") private var launchMinimized: Bool = false

    /// Keep failed registration visible beside the saved intent until it succeeds.
    @State private var loginItemIssue: LoginItemManager.RegistrationIssue?

    /// Defer the SMAppService register/unregister off the SwiftUI `.onChange`
    /// transaction - running it inline (synchronous, XPC-backed) mid-update
    /// dismissed the Settings window. The @AppStorage write still happens
    /// synchronously; only the side-effect hops to the next main-queue tick.
    private func scheduleLoginItemRegistration(launchAtLogin: Bool, minimized: Bool) {
        DispatchQueue.main.async {
            let status = LoginItemManager.apply(launchAtLogin: launchAtLogin, minimized: minimized)
            LoginItemManager.syncRelaunchOnLogin(launchAtLogin)
            loginItemIssue = LoginItemManager.registrationIssue(for: status)
        }
    }

    /// Default-launch app options - host applist with "Desktop" pinned first.
    private var launchAppOptions: [String] {
        var seen = Set<String>()
        var out: [String] = []
        for name in ["Desktop"] + (model.selectedHost?.apps.map(\.name) ?? [])
        where seen.insert(name).inserted {
            out.append(name)
        }
        let current = model.defaultLaunchApp
        if !current.isEmpty, seen.insert(current).inserted {
            out.append(current)
        }
        return out
    }

    /// Display label for a launch option: a stored app that isn't on the selected
    /// host (set on another PC) is annotated so the picker doesn't imply it'll
    /// launch here. Display-only - the tag stays the raw name, so scoping is unchanged.
    private func launchOptionLabel(_ name: String) -> String {
        guard name != "Desktop",
              let host = model.selectedHost,
              !host.apps.contains(where: { $0.name == name }) else { return name }
        return "\(name) (not on \(host.displayName))"
    }

    var body: some View {
        // @Bindable shim - surfaces $model.x bindings from an @Observable
        // environment value (the macro replaces ObservableObject; @Environment
        // alone exposes the value but not per-property Bindings).
        @Bindable var model = model
        Form {
            Section {
                Toggle("Open at login", isOn: $launchAtLogin)
                    .help("Adds Glimmer to System Settings › General › Login Items.")
                    .onChange(of: launchAtLogin) { _, on in
                        scheduleLoginItemRegistration(launchAtLogin: on, minimized: launchMinimized)
                    }
                // Only means something at login, so it appears with that switch rather than sitting disabled.
                if launchAtLogin {
                    Toggle(isOn: $launchMinimized) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Open in the menu bar only")
                            Text("Starts in the menu bar at login. Opening Glimmer from the Dock or Spotlight "
                                + "shows the window.")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .accessibilityLabel("Open in the menu bar only")
                    .onChange(of: launchMinimized) { _, on in
                        scheduleLoginItemRegistration(launchAtLogin: launchAtLogin, minimized: on)
                    }
                }
                if let loginItemIssue {
                    HStack(spacing: 8) {
                        Label(loginItemIssue == .failed
                              ? "Couldn't update Open at login. Try again."
                              : "macOS needs you to approve Glimmer in Login Items, "
                                + "or it won't start at the next reboot.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.orange)
                        Spacer()
                        if loginItemIssue == .failed {
                            Button("Try Again") {
                                scheduleLoginItemRegistration(launchAtLogin: launchAtLogin, minimized: launchMinimized)
                            }
                        }
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                Toggle(isOn: $model.muteMacWhileStreaming) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Play sound on the PC")
                        Text("Sound plays on the PC instead of this Mac. Other apps aren't affected. "
                            + "Applies to the next stream.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("Play sound on the PC")
            }
            Section {
                // Picker sourced from the selected host's announced app
                // list (Sunshine's `applist`). "Desktop" is always
                // present as a baseline; a stored choice missing from
                // the host's live applist (host offline at config time)
                // is preserved in the list so we don't silently lose it.
                Picker("Start with", selection: $model.defaultLaunchApp) {
                    ForEach(launchAppOptions, id: \.self) { name in
                        Text(launchOptionLabel(name)).tag(name)
                    }
                }
            } header: {
                Text("Streaming")
            } footer: {
                Text("To stream a different app once, click it in the launcher.")
            }
        }
        .formStyle(.grouped)
        .onAppear { refreshLoginItemState() }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshLoginItemState()
        }
    }

    /// Show what macOS actually has: a removal in System Settings turns the
    /// toggle off, a pending approval shows the warning. Deferred like the
    /// registration above, since reconcile may re-register.
    private func refreshLoginItemState() {
        Task { @MainActor in
            let status = await LoginItemManager.reconcile()
            if status != nil || loginItemIssue != .failed {
                loginItemIssue = LoginItemManager.registrationIssue(for: status)
            }
        }
    }
}

// MARK: - Quality

/// Resolution presets surfaced from the "common resolutions" menu next
/// to the custom resolution fields. Curated rather than exhaustive -
/// the user can still type any value they like; this is just a
/// no-typo shortcut for the 95% case (1080p / 1440p / 2160p).
enum CommonResolution: CaseIterable {
    case hd720, hd1080, qhd1440, uhd4K

    var width: Int {
        switch self {
        case .hd720: return 1280
        case .hd1080: return 1920
        case .qhd1440: return 2560
        case .uhd4K: return 3840
        }
    }
    var height: Int {
        switch self {
        case .hd720: return 720
        case .hd1080: return 1080
        case .qhd1440: return 1440
        case .uhd4K: return 2160
        }
    }
    var shortLabel: String {
        switch self {
        case .hd720: return "720p"
        case .hd1080: return "1080p"
        case .qhd1440: return "1440p"
        case .uhd4K: return "2160p"
        }
    }
}

struct QualityPane: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// The privileged AWDL network helper (parks awdl0 during streams). Shared
    /// singleton so this toggle and the stream lifecycle drive one instance.
    /// Lives in Quality because parking AirDrop's radio is a stream-smoothness
    /// lever, not a general app setting.
    @ObservedObject private var awdl = AWDLHelperManager.shared

    /// Defer the helper register/unregister off the SwiftUI transaction - an
    /// inline XPC-backed SMAppService call mid-update dismisses the Settings
    /// window.
    private func scheduleHelperToggle(_ enable: Bool) {
        Task { @MainActor in
            if enable { AWDLHelperManager.shared.enable() } else { AWDLHelperManager.shared.disable() }
        }
    }

    /// Text buffers for the Custom fields. The model only ever receives an
    /// in-range value, so a half-typed "1" can't become 480 under the cursor
    /// (#87). No @FocusState: one here dangled in SwiftUI's tooltip hit-test and crashed.
    @State private var customWidthText = ""
    @State private var customHeightText = ""
    @State private var customFPSText = ""

    /// Commit `text` to the model when it parses and sits inside `range`.
    private func commitCustomField(_ text: String, range: ClosedRange<Int>,
                                   to write: (Int) -> Void) {
        guard let value = StreamSizeBounds.acceptedValue(from: text, in: range) else { return }
        write(value)
    }

    /// Show the model's values: on appear, and after Return settles a stray edit.
    private func settleCustomFieldText() {
        customWidthText = String(model.customWidth)
        customHeightText = String(model.customHeight)
        customFPSText = String(model.customFPS)
    }

    var body: some View {
        // @Bindable shim - surfaces $model.x bindings from an @Observable
        // environment value (the macro replaces ObservableObject; @Environment
        // alone exposes the value but not per-property Bindings).
        @Bindable var model = model
        Form {
            // Header is "Preset" now that the pane itself is named Quality -
            // "Quality" twice in a row read as a stutter.
            Section {
                Picker("", selection: $model.qualityPreset) {
                    ForEach(QualityPreset.allCases) { preset in
                        VStack(alignment: .leading) {
                            Text(preset.displayName).fontWeight(.medium)
                            Text(preset.subtitle).font(.footnote).foregroundStyle(.secondary)
                        }
                        .tag(preset)
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
                // Nothing else lives in this card: a switch or a picker under
                // the radio rows read as extra preset rows (owner's screenshot).
            } header: {
                Text("Preset")
            } footer: {
                // Said once for the pane, under whichever card ends the preset choice.
                if model.qualityPreset != .custom { Text("Changes here apply to the next stream.") }
            }

            if model.qualityPreset == .custom { customSection }

            // Bandwidth in its own card, segmented like "Show the stream": two
            // values, read at a glance. The number under "Your next stream"
            // moves with it; the session takes it at launch.
            Section {
                Picker("Bandwidth", selection: $model.bitrateMode) {
                    ForEach(BitrateMode.allCases) { mode in
                        Text(mode.displayName).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .help("Highest quality asks for the most the link can carry: twice the usual bitrate over Ethernet, "
                    + "or half as much again over Wi-Fi, held to what the radio is doing. "
                    + "Bandwidth saver asks for the usual bitrate.")
            } footer: {
                Text("Highest quality gives every frame more bits, which keeps fine detail from turning to grain. "
                    + "On Wi-Fi it follows what the radio can carry. Bandwidth saver uses less.")
            }

            // Beside Bandwidth: the couch player's network controls, in the pane's first screen.
            Section("Wi-Fi") {
                Toggle(isOn: Binding(get: { awdl.isRegistered }, set: { scheduleHelperToggle($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Smooth out Wi-Fi stutter while streaming").fontWeight(.medium)
                        Text("Pauses AirDrop and Continuity while you stream, so they can't take over "
                            + "the Wi-Fi and freeze the picture. They come back the moment you stop. "
                            + "Needs a one-time approval.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .accessibilityLabel("Smooth out Wi-Fi stutter while streaming")
                .help("Installs a small helper that pauses AirDrop's radio for each stream.")
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

            // One HDR switch for every preset, on by default; off asks the PC
            // for SDR. Read at session start, like Bandwidth.
            Section {
                Toggle("HDR", isOn: $model.streamHDR)
                    .toggleStyle(.switch)
                    .help("Sends a 10-bit high-dynamic-range stream when the PC and this display both support it. "
                        + "Off asks the PC for SDR.")
            } footer: {
                Text("Brighter highlights and deeper color when the PC and this display both support HDR.")
            }

            if model.effectiveDisplayMode == .fullScreen {
                Section {
                    if model.currentDisplayHasNotch {
                        Toggle("Keep picture below the camera", isOn: Binding(
                            get: { !model.streamCoversNotch }, set: { model.streamCoversNotch = !$0 }))
                            .toggleStyle(.switch)
                            .help("Uses a macOS full-screen Space below the notch. Off covers the whole panel.")
                    } else {
                        Toggle("Use a full-screen Space", isOn: $model.streamUsesFullScreenSpace)
                            .toggleStyle(.switch)
                            .help("Opens the next stream in a separate macOS Space. Off covers the current desktop.")
                    }
                } footer: {
                    if model.currentDisplayHasNotch {
                        Text("Off, a thin strip of the picture hides behind the notch.")
                    }
                    Text("macOS may turn on Game Mode. Change it in Game Overlay › Settings › Game Mode.")
                }
            }

            Section {
                Toggle("Stream stats", isOn: $model.showStreamStats)
                // Footnote tracks the actual configured chord so it stays
                // accurate if the user rebinds the hotkey in Input.
                Text("A small overlay over the picture with ping, frame rate and decode time. Press "
                    + "\(model.statsHotkey.displayString) while streaming to show or hide it; you can change "
                    + "the shortcut in Settings › Input.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                // Configuration stays available while the HUD is hidden.
                Picker("Position", selection: $model.streamStatsCorner) {
                    ForEach(StatsOverlayCorner.allCases, id: \.self) { corner in
                        Text(corner.displayName).tag(corner)
                    }
                }

                Picker("Overlay detail", selection: $model.statsOverlayPreset) {
                    ForEach(StatsOverlayPreset.allCases, id: \.self) { preset in
                        VStack(alignment: .leading) {
                            Text(preset.displayName).fontWeight(.medium)
                            Text(presetSubtitle(preset))
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        .tag(preset)
                    }
                }
                .pickerStyle(.inline)

                if model.statsOverlayPreset == .custom {
                    StatsCustomRowsPicker()
                }

                // Outcome-named: this is what the thresholds DO, not what
                // they are. The editor inside still says warn/critical.
                DisclosureGroup("When numbers turn yellow or red") {
                    StatsThresholdsEditor()
                }
            }

            Section("Your next stream") {
                Text(model.streamSpecSummary)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .animation(reduceMotion ? nil : .snappy, value: model.qualityPreset)
        .onAppear { awdl.refresh() }
    }

    /// Custom's choices, in a card of their own straight under the preset card: rows inside that
    /// card read as more presets. Window is a Custom thing; the panel-native presets are full screen.
    @ViewBuilder private var customSection: some View {
        @Bindable var model = model
        Section {
            Picker("Show the stream", selection: $model.streamDisplayMode) {
                ForEach(StreamDisplayMode.allCases) { mode in
                    Text(mode.displayName).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .help("Window opens the stream as a normal window at the size below; drag it to any size.")
            HStack {
                Text("Resolution")
                Spacer()
                // One tap fills both fields with a standard pair, so nobody lands at 384 × 216.
                Menu {
                    ForEach(CommonResolution.allCases, id: \.self) { res in
                        Button("\(res.width) × \(res.height) · \(res.shortLabel)") {
                            model.customWidth = res.width
                            model.customHeight = res.height
                        }
                    }
                } label: {
                    Text("Presets")
                }
                .menuStyle(.button)
                .help("Common resolutions")
                .fixedSize()
                TextField("", text: $customWidthText)
                    .frame(width: 70)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .onChange(of: customWidthText) { _, text in
                        commitCustomField(text, range: StreamSizeBounds.width) { model.customWidth = $0 }
                    }
                    .onChange(of: model.customWidth) { _, value in customWidthText = String(value) }
                    .onSubmit { settleCustomFieldText() }
                Text("×").foregroundStyle(.secondary)
                TextField("", text: $customHeightText)
                    .frame(width: 70)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .onChange(of: customHeightText) { _, text in
                        commitCustomField(text, range: StreamSizeBounds.height) { model.customHeight = $0 }
                    }
                    .onChange(of: model.customHeight) { _, value in customHeightText = String(value) }
                    .onSubmit { settleCustomFieldText() }
            }
            HStack {
                Text("Refresh rate")
                Spacer()
                TextField("", text: $customFPSText)
                    .frame(width: 60)
                    .multilineTextAlignment(.trailing)
                    .monospacedDigit()
                    .onChange(of: customFPSText) { _, text in
                        commitCustomField(text, range: StreamSizeBounds.fps) { model.customFPS = $0 }
                    }
                    .onChange(of: model.customFPS) { _, value in customFPSText = String(value) }
                    .onSubmit { settleCustomFieldText() }
                Text("Hz").foregroundStyle(.secondary)
            }
            .onAppear { settleCustomFieldText() }
            // No bitrate row: Glimmer picks it from measured anchors, shown under "Your next stream".
            HStack {
                Text("Currently driving: \(model.currentDisplayDescription)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Use Native Resolution") {
                    model.snapCustomToDisplay()
                }
                .buttonStyle(.borderless)
            }
        } footer: {
            // A window's one surprise: the game takes the mouse while the pointer is over it.
            Text(model.streamDisplayMode == .window
                ? "Changes here apply to the next stream. The game takes your mouse while the pointer is over "
                    + "the window. Hold Esc or switch apps to get it back."
                : "Changes here apply to the next stream.")
        }
    }

    /// Per-preset hint string. Kept inline alongside the picker so the
    /// preset definitions and their UI copy live in the same file -
    /// translating into Localizable.strings later means moving both
    /// together.
    private func presetSubtitle(_ preset: StatsOverlayPreset) -> String {
        // Counts derive from the row-set constants so the copy can't
        // drift when a preset gains a row - the hardcoded "6 metrics"
        // survived microRows growing to 7 with zero signal.
        switch preset {
        case .minimal:
            return "\(StatsOverlayDefaults.minimalRows.count) metrics: FPS, latency, bitrate, codec"
        case .micro:
            return "\(StatsOverlayDefaults.microRows.count) metrics: frame rate, network, bitrate"
        case .extended: return "All stream metrics (not audio or Mac vitals)"
        case .custom:   return "Pick rows individually below"
        }
    }
}

// MARK: - Stats custom rows picker
//
// Standalone view (not inlined in the QualityPane) because the
// Section{} body in SwiftUI's Form has tight rules about what counts as
// a single row vs. a multi-row group, and a grouped checkbox grid sits
// most cleanly as its own view. Reads + writes the manager directly via
// @Environment; no separate binding plumbing.
struct StatsCustomRowsPicker: View {
    @Environment(AppModel.self) private var model

    /// Row catalogue grouped by section for display. The order here
    /// matches the rendering order in StreamStatsSnapshot.rows() - the
    /// user sees the same top-to-bottom shape in the checkbox list as
    /// in the overlay. Audio sits at the bottom and is unchecked by
    /// default; users opt in via Custom.
    private static let sections: [(title: String, rows: [(StatsRow.Kind, String)])] = [
        ("Frame rates", [
            (.hostFps, "PC FPS"),
            (.networkFps, "Network FPS"),
            (.decodeFps, "Decode FPS"),
            (.renderFps, "Render FPS")
        ]),
        ("Network", [
            (.latency, "Latency"),
            (.jitter, "Jitter"),
            (.networkDrops, "Network drop rate")
        ]),
        ("Pipeline", [
            (.decoderDrops, "Decoder drops"),
            (.smoothness, "Smoothness"),
            (.decodeTime, "Decode time"),
            (.bitrate, "Bitrate"),
            (.hostProcessing, "PC encode latency")
        ]),
        ("Mac", [
            (.macCpu, "Mac CPU"),
            (.macRam, "Mac RAM"),
            (.macBattery, "Mac battery"),
            (.controllerBattery, "Controller battery")
        ]),
        ("Config", [
            (.codec, "Video codec"),
            (.audio, "Audio configuration")
        ])
    ]

    init() {
        // Exhaustiveness tripwire: every StatsRow.Kind must appear in the
        // hand-maintained catalogue above, or that row silently becomes
        // un-toggleable in Custom (how .smoothness went missing - added
        // to the enum and Extended, never to this list). Debug-only;
        // assert() compiles out of release builds.
        assert(
            Set(Self.sections.flatMap { $0.rows.map(\.0) }) == Set(StatsRow.Kind.allCases),
            "Custom-rows catalogue is out of sync with StatsRow.Kind.allCases")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            ForEach(Self.sections, id: \.title) { section in
                VStack(alignment: .leading, spacing: 4) {
                    Text(section.title)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundStyle(.secondary)
                        .textCase(.uppercase)
                    ForEach(section.rows, id: \.0) { row in
                        Toggle(row.1, isOn: rowBinding(for: row.0))
                            .toggleStyle(.checkbox)
                    }
                }
            }
        }
        .padding(.top, 6)
    }

    /// Two-way binding for one row's membership in the custom-rows set.
    /// Set-mutation goes through the property's didSet so the
    /// UserDefaults persistence kicks in on every toggle.
    private func rowBinding(for kind: StatsRow.Kind) -> Binding<Bool> {
        Binding(
            get: { model.statsOverlayCustomRows.contains(kind) },
            set: { isOn in
                if isOn {
                    model.statsOverlayCustomRows.insert(kind)
                } else {
                    model.statsOverlayCustomRows.remove(kind)
                }
            }
        )
    }
}
