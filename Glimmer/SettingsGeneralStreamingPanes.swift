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

    /// True when macOS has the login item but it's pending the user's approval
    /// in System Settings ▸ Login Items - surfaced inline so the user isn't left
    /// with a toggle that silently does nothing at the next reboot.
    @State private var loginItemNeedsApproval = false

    /// Defer the SMAppService register/unregister off the SwiftUI `.onChange`
    /// transaction - running it inline (synchronous, XPC-backed) mid-update
    /// dismissed the Settings window. The @AppStorage write still happens
    /// synchronously; only the side-effect hops to the next main-queue tick.
    private func scheduleLoginItemRegistration(launchAtLogin: Bool, minimized: Bool) {
        DispatchQueue.main.async {
            let status = LoginItemManager.apply(launchAtLogin: launchAtLogin, minimized: minimized)
            loginItemNeedsApproval = (status == .requiresApproval)
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
                Toggle("Open in the menu bar only", isOn: $launchMinimized)
                    .onChange(of: launchMinimized) { _, on in
                        scheduleLoginItemRegistration(launchAtLogin: launchAtLogin, minimized: on)
                    }
                    .disabled(!launchAtLogin)
                Text("At login, Glimmer can start in the menu bar without showing its window. "
                    + "Opening it from the Dock, Finder or Spotlight always shows the window.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if loginItemNeedsApproval {
                    HStack(spacing: 8) {
                        Label("macOS needs you to approve Glimmer in Login Items, "
                            + "or it won't start at the next reboot.",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.footnote).foregroundStyle(.orange)
                        Spacer()
                        Button("Open Login Items") { SMAppService.openSystemSettingsLoginItems() }
                    }
                }
                Toggle("Mute this Mac while streaming", isOn: $model.muteMacWhileStreaming)
                Text("Turns this Mac's volume all the way down while you stream, so other apps go quiet "
                    + "too, and back up when you stop. The PC doesn't play the sound instead.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Default action") {
                // Picker sourced from the selected host's announced app
                // list (Sunshine's `applist`). "Desktop" is always
                // present as a baseline; a stored choice missing from
                // the host's live applist (host offline at config time)
                // is preserved in the list so we don't silently lose it.
                Picker("On connect, launch", selection: $model.defaultLaunchApp) {
                    ForEach(launchAppOptions, id: \.self) { name in
                        Text(launchOptionLabel(name)).tag(name)
                    }
                }
                Text("Right-click the Stream button to pick a different app per connection.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
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
        DispatchQueue.main.async {
            loginItemNeedsApproval = (LoginItemManager.reconcile() == .requiresApproval)
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
            Section("Preset") {
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
            }

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
                    + "Bandwidth saver uses less. Applies next stream.")
            }

            // One HDR switch for every preset, on by default; off asks the PC
            // for SDR. Read at session start, like Bandwidth.
            Section {
                Toggle("HDR", isOn: $model.streamHDR)
                    .toggleStyle(.switch)
                    .help("Sends a 10-bit high-dynamic-range stream when the PC and this display both support it. "
                        + "Off asks the PC for SDR.")
            } footer: {
                Text("Brighter highlights, deeper color (needs HDR on the PC and this display). Applies next stream.")
            }

            // Notch coverage in its own compact card. DEFAULT ON: full-panel
            // coverage is the product stance on notched MacBooks. Shown ONLY on
            // a notched panel and only for a full-screen stream: elsewhere the
            // toggle used to silently switch the fullscreen mechanism to a
            // macOS Space (issue #84), so notchless Macs now always take the
            // cover and never see the switch. Snapshotted at session start, so
            // the next-stream caveat lives in the footer; the .help() carries
            // the detail.
            if model.currentDisplayHasNotch, model.effectiveDisplayMode == .fullScreen {
                Section {
                    Toggle("Fill the notch", isOn: $model.streamCoversNotch)
                        .toggleStyle(.switch)
                        .help("Covers the whole panel, camera notch included, so a panel-native stream renders 1:1. "
                            + "Off keeps the picture below the notch by using a macOS full-screen space.")
                } footer: {
                    Text("A thin strip of the picture hides behind the notch. Off keeps it clear, "
                        + "using a macOS full-screen space. Applies next stream.")
                }
            }

            if model.qualityPreset == .custom {
                // "Custom" alone: the section owns the window choice now, not
                // just overrides of the preset numbers.
                Section {
                    // Window is a Custom thing - the panel-native presets are
                    // full screen by definition - so the choice leads the
                    // section, segmented (reads instantly; a two-value chevron
                    // looked cheap next to the radio rows). Persisted as the
                    // display mode; snapshotted at session start.
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
                        // Common resolutions shortcut - one tap fills both
                        // fields with a standard pair. Saves the user from
                        // typing 3840×2160 every time and prevents typos
                        // that would land them at 384×216.
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
                    // No bitrate row. Asking someone to pick a wire budget -
                    // and then to decide whether we should pick it for them -
                    // is two questions we can answer better ourselves from the
                    // measured anchors (AppModel.measuredBitrateAnchors). The
                    // resulting figure is in the next-stream summary below.
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
                } header: {
                    Text("Custom")
                } footer: {
                    // The one non-obvious thing about a window: the mouse
                    // disappears into the game the moment it is over the
                    // picture, so say up front how to get it back.
                    if model.streamDisplayMode == .window {
                        Text("The game takes your mouse while the pointer is over the window. "
                            + "Hold Esc or switch apps to get it back.")
                    }
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
                // Overlay position lives here (not a right-click menu - the
                // InputForwarder claims mouse events mid-stream). Position +
                // preset + custom rows stay editable even when the overlay is
                // off, so it's gating display, not configuration.
                Picker("Overlay position", selection: $model.streamStatsCorner) {
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

            Section("Wi-Fi") {
                Toggle(isOn: Binding(get: { awdl.isRegistered }, set: { scheduleHelperToggle($0) })) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Smooth out Wi-Fi stutter while streaming").fontWeight(.medium)
                        Text("Parks AirDrop's radio (AWDL) for the length of a stream so it can't "
                            + "grab the Wi-Fi channel and cause multi-second freezes. Restored the "
                            + "instant you stop. Installs a small helper that needs a one-time approval.")
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                }
                .help("Holds awdl0 down for the duration of each stream via a privileged helper.")
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

            Section("Your next stream") {
                Text(model.streamSpecSummary)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // No Experiments section yet. Don't emit an empty `Section { } header: { Label("Experiments", systemImage: "flask") }` — SwiftUI's grouped Form renders the Section header even over an EmptyView body, leaving a dangling flask card. Add the Section back together with the first real dial.
        }
        .formStyle(.grouped)
        .onAppear { awdl.refresh() }
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
            return "\(StatsOverlayDefaults.minimalRows.count) metrics: render FPS, latency, bitrate"
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
            (.hostFps, "Host FPS"),
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
            (.hostProcessing, "Host encode latency")
        ]),
        ("Mac", [
            (.macCpu, "Mac CPU"),
            (.macRam, "Mac RAM"),
            (.macBattery, "Mac battery"),
            (.controllerBattery, "Controller battery")
        ]),
        ("Config", [
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
