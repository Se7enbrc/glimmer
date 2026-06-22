//
//  SettingsGeneralStreamingPanes.swift
//
//  The General and Quality settings panes (+ their resolution/stats helpers),
//  split out of SettingsView.swift. SettingsRoot composes them across files, so
//  the pane types are internal. (Filename keeps the pane's pre-rename
//  "Streaming" spelling - renaming the file means touching the pbxproj for
//  zero behavioural gain.)
//

import AppKit
import os
import ServiceManagement
import SwiftUI

// MARK: - Login item

/// Owns the SMAppService login-item lifecycle, shared by the General toggles
/// and the launch-time reconcile. Registration is keyed by the user's saved
/// intent (UserDefaults `launchAtLogin` / `launchMinimized`):
///   * minimized → register the HELPER (relaunches the main app suppressed)
///   * not minimized → register the main app (normal open at login)
enum LoginItemManager {
    static let helperBundleID = "io.ugfugl.Glimmer.LoginHelper"

    /// The service that backs the user's current intent.
    private static func activeService(minimized: Bool) -> SMAppService {
        minimized ? SMAppService.loginItem(identifier: helperBundleID) : SMAppService.mainApp
    }

    /// Apply the desired state, returning the resulting status so the caller can
    /// prompt for approval. Surfaces failures to the in-app log (the old code
    /// swallowed them into os_log, which is why a broken registration looked
    /// fine until the next reboot never happened).
    @discardableResult
    static func apply(launchAtLogin: Bool, minimized: Bool) -> SMAppService.Status {
        let helper = SMAppService.loginItem(identifier: helperBundleID)
        let mainApp = SMAppService.mainApp
        do {
            guard launchAtLogin else {
                if helper.status == .enabled { try helper.unregister() }
                if mainApp.status == .enabled { try mainApp.unregister() }
                Diag.info("login item disabled", "LoginItem")
                return .notRegistered
            }
            if minimized {
                if mainApp.status == .enabled { try mainApp.unregister() }
                try helper.register()
                Diag.notice("login item registered (helper) → \(statusLabel(helper.status))", "LoginItem")
                return helper.status
            } else {
                if helper.status == .enabled { try helper.unregister() }
                try mainApp.register()
                Diag.notice("login item registered (main app) → \(statusLabel(mainApp.status))", "LoginItem")
                return mainApp.status
            }
        } catch {
            Diag.error("login item registration FAILED: \(error.localizedDescription)", "LoginItem")
            return .notFound
        }
    }

    /// Re-assert the saved intent at launch so a registration invalidated by an
    /// app update / move self-heals - the root cause of "doesn't start after
    /// reboot". Runs only when the user wants launch-at-login, and only
    /// re-registers when the actual status has drifted from enabled.
    static func reconcile() {
        guard UserDefaults.standard.bool(forKey: "launchAtLogin") else { return }
        let minimized = UserDefaults.standard.bool(forKey: "launchMinimized")
        let status = activeService(minimized: minimized).status
        switch status {
        case .enabled:
            Diag.info("login item enabled (\(minimized ? "helper" : "main app"))", "LoginItem")
        case .requiresApproval:
            Diag.notice("login item needs approval in System Settings ▸ General ▸ Login Items", "LoginItem")
        default:
            Diag.notice("login item drifted (\(statusLabel(status))) - re-registering", "LoginItem")
            apply(launchAtLogin: true, minimized: minimized)
        }
    }

    static func statusLabel(_ status: SMAppService.Status) -> String {
        switch status {
        case .notRegistered: return "not registered"
        case .enabled: return "enabled"
        case .requiresApproval: return "requires approval"
        case .notFound: return "not found"
        @unknown default: return "unknown"
        }
    }
}

// MARK: - General

struct GeneralPane: View {
    @Environment(MoonlightManager.self) private var moonlight
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
        for name in ["Desktop"] + (moonlight.selectedHost?.apps.map(\.name) ?? [])
        where seen.insert(name).inserted {
            out.append(name)
        }
        let current = moonlight.defaultLaunchApp
        if !current.isEmpty, seen.insert(current).inserted {
            out.append(current)
        }
        return out
    }

    var body: some View {
        // @Bindable shim - surfaces $moonlight.x bindings from an @Observable
        // environment value (the macro replaces ObservableObject; @Environment
        // alone exposes the value but not per-property Bindings).
        @Bindable var moonlight = moonlight
        Form {
            Section {
                // Outcome-first labels: what the user feels, with the
                // tradeoff in the parenthetical. The mechanism (login items,
                // SMAppService) stays in code comments and help text.
                Toggle("Be ready at login (starts automatically with your Mac)", isOn: $launchAtLogin)
                    .help("Registers Glimmer as a macOS login item.")
                    .onChange(of: launchAtLogin) { _, on in
                        scheduleLoginItemRegistration(launchAtLogin: on, minimized: launchMinimized)
                    }
                Toggle("Stay hidden at login (menu bar only until you ask)", isOn: $launchMinimized)
                    .onChange(of: launchMinimized) { _, on in
                        scheduleLoginItemRegistration(launchAtLogin: launchAtLogin, minimized: on)
                    }
                    .disabled(!launchAtLogin)
                Text("When on, Glimmer launches into the menu bar at login without showing the "
                    + "main window. Toggle it off to have the launcher open at login like a normal "
                    + "app. Manual launches via Spotlight, Finder, or the Dock always open the window.")
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
                Toggle("Mute this Mac while streaming", isOn: $moonlight.muteMacWhileStreaming)
                Text("Keeps game audio on the gaming PC's output only; this Mac stays silent "
                    + "for the length of the stream.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Section("Default action") {
                // Picker sourced from the selected host's announced app
                // list (Sunshine's `applist`). "Desktop" is always
                // present as a baseline; a stored choice missing from
                // the host's live applist (host offline at config time)
                // is preserved in the list so we don't silently lose it.
                Picker("On connect, launch", selection: $moonlight.defaultLaunchApp) {
                    ForEach(launchAppOptions, id: \.self) { name in
                        Text(name).tag(name)
                    }
                }
                Text("Right-click the Stream button to pick a different app per connection.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .onAppear {
            guard launchAtLogin else { loginItemNeedsApproval = false; return }
            let service = launchMinimized
                ? SMAppService.loginItem(identifier: LoginItemManager.helperBundleID)
                : SMAppService.mainApp
            loginItemNeedsApproval = (service.status == .requiresApproval)
        }
    }
}

// MARK: - Quality

/// Resolution presets surfaced from the "common resolutions" menu next
/// to the custom resolution fields. Curated rather than exhaustive -
/// the user can still type any value they like; this is just a
/// no-typo shortcut for the 95% case (1080p / 1440p / 2160p).
enum CommonResolution: CaseIterable {
    case hd1080, qhd1440, uhd4K, hd720

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
    @Environment(MoonlightManager.self) private var moonlight

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

    /// Width clamp: 640..7680 (480p min, 8K max). Matches Moonlight's
    /// upstream bounds. Wired to .onChange so it runs on EVERY commit:
    /// TextField(value:format:) writes the binding whenever editing ends -
    /// focus loss included - and the old Return-only .onSubmit clamp let a
    /// click-away commit feed raw values (0, 99999) straight into the
    /// stream config, the bitrate guidance, and the session-receipt mode
    /// keys. The binding still only commits on editing end (never per
    /// keystroke), so the clamp can't fight a transient mid-edit value.
    /// Bounds mirror the init()-time heal in MoonlightManager.
    private func clampCustomResolution() {
        if moonlight.customWidth < 640 { moonlight.customWidth = 640 }
        if moonlight.customWidth > 7680 { moonlight.customWidth = 7680 }
        if moonlight.customHeight < 480 { moonlight.customHeight = 480 }
        if moonlight.customHeight > 4320 { moonlight.customHeight = 4320 }
    }
    /// FPS clamp: 30..240. Sunshine + GFE both refuse anything outside
    /// this band; clamping at the UI saves a confused stream-failure
    /// trip. Same every-commit .onChange wiring as the resolution clamp.
    private func clampCustomFPS() {
        if moonlight.customFPS < 30 { moonlight.customFPS = 30 }
        if moonlight.customFPS > 240 { moonlight.customFPS = 240 }
    }

    var body: some View {
        // @Bindable shim - surfaces $moonlight.x bindings from an @Observable
        // environment value (the macro replaces ObservableObject; @Environment
        // alone exposes the value but not per-property Bindings).
        @Bindable var moonlight = moonlight
        Form {
            // Header is "Preset" now that the pane itself is named Quality -
            // "Quality" twice in a row read as a stutter.
            Section("Preset") {
                Picker("", selection: $moonlight.qualityPreset) {
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

                // Notch coverage as a compact pill right under the resolution
                // choice - it shapes the same picture. DEFAULT ON: full-panel
                // coverage is the product stance on notched MacBooks. Only
                // meaningful on built-in notched panels; elsewhere the safe-area
                // inset is zero and the toggle is a no-op. Snapshotted at session
                // start, so the next-stream caveat lives in the description.
                Toggle("Fill the notch", isOn: $moonlight.streamCoversNotch)
                    .toggleStyle(.switch)
                    .help("Covers the whole panel on notched MacBooks; a sliver of the image hides behind the camera notch.")
                Text("Fills the whole panel on notched MacBooks - a thin strip of the picture "
                    + "hides behind the notch. Off keeps it clear. Applies next stream.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }

            if moonlight.qualityPreset == .custom {
                Section("Custom overrides") {
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
                                    moonlight.customWidth = res.width
                                    moonlight.customHeight = res.height
                                }
                            }
                        } label: {
                            Image(systemName: "rectangle.on.rectangle")
                                .symbolRenderingMode(.hierarchical)
                        }
                        .menuStyle(.borderlessButton)
                        .menuIndicator(.hidden)
                        .help("Common resolutions")
                        .fixedSize()
                        TextField("", value: $moonlight.customWidth, format: .number)
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .onChange(of: moonlight.customWidth) { _, _ in clampCustomResolution() }
                        Text("×").foregroundStyle(.secondary)
                        TextField("", value: $moonlight.customHeight, format: .number)
                            .frame(width: 70)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .onChange(of: moonlight.customHeight) { _, _ in clampCustomResolution() }
                    }
                    HStack {
                        Text("Refresh rate")
                        Spacer()
                        TextField("", value: $moonlight.customFPS, format: .number)
                            .frame(width: 60)
                            .multilineTextAlignment(.trailing)
                            .monospacedDigit()
                            .onChange(of: moonlight.customFPS) { _, _ in clampCustomFPS() }
                        Text("Hz").foregroundStyle(.secondary)
                    }
                    Toggle("Keep bitrate matched automatically (follows resolution and refresh)",
                           isOn: $moonlight.customBitrateAuto)
                        .help("Recomputes the bitrate whenever resolution or refresh changes. Turn off to set your own.")
                    HStack {
                        Text("Bitrate")
                        Spacer()
                        Slider(value: Binding(
                            get: { Double(moonlight.customBitrateMbps) },
                            set: { moonlight.customBitrateMbps = Int($0) }
                        ), in: 5...200, step: 1)
                        .frame(width: 200)
                        .disabled(moonlight.customBitrateAuto)
                        Text("\(moonlight.customBitrateMbps) Mbps")
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                            .frame(width: 80, alignment: .trailing)
                    }
                    bitrateGuidance
                    Toggle("Brighter highlights, deeper color (needs HDR on host and display)",
                           isOn: $moonlight.customHDR)
                        .help("HDR - sends a 10-bit high-dynamic-range stream when the host and this display both support it.")
                    HStack {
                        Text("Currently driving: \(moonlight.currentDisplayDescription)")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        Button("Use native resolution") {
                            moonlight.snapCustomToDisplay()
                        }
                        .buttonStyle(.borderless)
                    }
                }
            }

            Section {
                Toggle("Watch the stream's health while you play (small overlay over the picture)",
                       isOn: $moonlight.showStreamStats)
                // Footnote tracks the actual configured chord so it stays
                // accurate if the user rebinds the hotkey in Shortcuts.
                Text("Ping, frame rate, decode time. Press \(moonlight.statsHotkey.displayString) "
                    + "(configurable in Shortcuts) while streaming to toggle the overlay.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                // Overlay position lives here (not a right-click menu - the
                // InputForwarder claims mouse events mid-stream). Position +
                // preset + custom rows stay editable even when the overlay is
                // off, so it's gating display, not configuration.
                Picker("Overlay position", selection: $moonlight.streamStatsCorner) {
                    ForEach(StatsOverlayCorner.allCases, id: \.self) { corner in
                        Text(corner.displayName).tag(corner)
                    }
                }

                Picker("Overlay detail", selection: $moonlight.statsOverlayPreset) {
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

                if moonlight.statsOverlayPreset == .custom {
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
                    Label("Network helper unavailable: \(why)", systemImage: "xmark.octagon")
                        .font(.footnote).foregroundStyle(.red)
                }
            }

            Section("Your next stream") {
                Text(moonlight.streamSpecSummary)
                    .font(.callout.monospacedDigit())
                    .foregroundStyle(.secondary)
            }

            // No Experiments section yet. Don't emit an empty `Section { } header: { Label("Experiments", systemImage: "flask") }` — SwiftUI's grouped Form renders the Section header even over an EmptyView body, leaving a dangling flask card. Add the Section back together with the first real dial.
        }
        .formStyle(.grouped)
        .onAppear { awdl.refresh() }
    }

    /// Two-tier bitrate guidance under the slider. Tier 1 is the baked-in
    /// measured recommendation (harness measurements + 20% headroom - provenance
    /// on `MoonlightManager.measuredBitrateAnchors`); Tier 2 speaks only when the
    /// user's own recent sessions for this exact host+mode pressed the
    /// encoder's ceiling. The closing footnote keeps the budget honest.
    private var bitrateGuidance: some View {
        let width = moonlight.customWidth
        let height = moonlight.customHeight
        let fps = moonlight.customFPS
        let mode = "\(MoonlightManager.resolutionLabel(width: width, height: height))·\(fps)"
        let recommended = moonlight.recommendedBitrateMbps(width: width, height: height, fps: fps)
        return VStack(alignment: .leading, spacing: 4) {
            Text("Recommended for \(mode): ~\(recommended) Mbps")
                .font(.footnote)
                .foregroundStyle(.secondary)
            if let advice = moonlight.learnedBitrateAdvice(
                hostID: moonlight.selectedHost?.id, width: width, height: height, fps: fps,
                wireBudgetMbps: moonlight.customBitrateMbps) {
                Text(advice)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Text("The bitrate is a wire budget: the encoder gets 80%, forward-error-correction takes 20%.")
                .font(.footnote)
                .foregroundStyle(.tertiary)
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
            return "\(StatsOverlayDefaults.minimalRows.count) metrics - render FPS, latency, bitrate"
        case .micro:
            return "\(StatsOverlayDefaults.microRows.count) metrics - framerate, network, bitrate"
        case .extended: return "All metrics except audio"
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
    @Environment(MoonlightManager.self) private var moonlight

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
            get: { moonlight.statsOverlayCustomRows.contains(kind) },
            set: { isOn in
                if isOn {
                    moonlight.statsOverlayCustomRows.insert(kind)
                } else {
                    moonlight.statsOverlayCustomRows.remove(kind)
                }
            }
        )
    }
}
