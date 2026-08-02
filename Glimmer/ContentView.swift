import SwiftUI
import AppKit

// MARK: - Main Window

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var showAWDLPrompt = false
    @State private var awdlPromptChecked = false

    var body: some View {
        @Bindable var model = model
        return Group {
            if model.hosts.isEmpty {
                EmptyPairingState()
            } else {
                ConnectSurface()
            }
        }
        // One-time proactive offer when a DualSense is connected (see
        // maybeOfferRawHID) - explains the feature before macOS's Input
        // Monitoring prompt; declining never re-asks.
        .alert("Enable enhanced DualSense buttons?", isPresented: $model.showRawHIDPrompt) {
            Button("Enable") { model.enableRawHIDFromPrompt() }
            Button("Cancel", role: .cancel) { model.declineRawHIDPrompt() }
        } message: {
            Text(AppModel.rawHIDExplanation)
        }
        // One-time launch nudge to enable Wi-Fi stutter protection. Only for
        // users who've paired a PC (skips first-run onboarding), never while the
        // rawHID prompt is up; "Don't ask again" inside silences it for good.
        .sheet(isPresented: $showAWDLPrompt) {
            AWDLEnablePrompt(manager: AWDLHelperManager.shared)
        }
        .task {
            guard !awdlPromptChecked else { return }
            awdlPromptChecked = true
            // Let hosts load + the window settle before deciding - checking
            // hosts.isEmpty immediately on appear raced the async host load,
            // so the prompt never fired.
            try? await Task.sleep(for: .seconds(1.0))
            AWDLHelperManager.shared.refresh()
            // Parking awdl0 only smooths Wi-Fi; on a confirmed wired route it's
            // a privileged-helper install for nothing. Suppress ONLY on .wired -
            // Wi-Fi / tunnel / still-resolving unknown still prompt.
            guard !model.hosts.isEmpty,
                  !model.showRawHIDPrompt,
                  model.hostRoute.routeClass != .wired,
                  AWDLHelperManager.shared.shouldPromptToEnable else { return }
            showAWDLPrompt = true
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            // Disconnect-beat toast - a brief, calm acknowledgement after a
            // stream ends instead of the launcher just snapping back.
            StreamEndedToast()
                .padding(.top, 16)
        }
        // Takeover confirmation: launching over a host that's already streaming
        // someone else's session boots them out, so confirm before we /launch.
        .confirmationDialog(
            "Take over the stream?",
            isPresented: Binding(
                get: { model.pendingTakeover != nil },
                set: { if !$0 { model.pendingTakeover = nil } }
            ),
            titleVisibility: .visible,
            presenting: model.pendingTakeover
        ) { _ in
            Button("Take over", role: .destructive) { model.confirmPendingTakeover() }
            Button("Cancel", role: .cancel) { model.pendingTakeover = nil }
        } message: { pending in
            Text("\(pending.host.displayName) is already streaming \(pending.occupantApp). Starting your stream will end that session.")
        }
        .background {
            // ⌘1-⌘9 host switching (multi-PC households only) - invisible,
            // window-scoped. See HostSwitchShortcuts for why hidden buttons
            // beat toolbar-menu shortcuts or app-level .commands here.
            HostSwitchShortcuts()
        }
        // Unpairing the LAST PC swaps ConnectSurface out for the empty state,
        // which merely CANCELS its route-monitor task - cancellation never
        // runs monitor(nil), leaving the parked UDP socket watching the
        // forgotten host's route until quit. Key on emptiness; release it
        // (selectedHost is nil here → monitor(address: nil), the teardown).
        .task(id: model.hosts.isEmpty) {
            if model.hosts.isEmpty { model.refreshHostRoute() }
        }
        .toolbar {
            // Single navigation pill merging the host dropdown with the
            // Settings gear. With zero hosts paired the host menu has nothing
            // to point at, so the pill collapses to a standalone gear button.
            ToolbarItem(placement: .navigation) {
                if model.hosts.isEmpty {
                    Button {
                        openSettings()
                    } label: {
                        Image(systemName: "gearshape")
                            .symbolRenderingMode(.hierarchical)
                    }
                    .keyboardShortcut(",", modifiers: .command)
                    .help("Settings")
                } else {
                    HostAndSettingsPill()
                }
            }
        }
        .navigationTitle("Glimmer")
    }
}

/// Invisible ⌘1-⌘9 host-switch shortcuts, mounted behind the launcher when
/// more than one PC is paired. Zero-size transparent buttons are the reliable
/// window-scoped registration here: toolbar-Menu items only exist while the
/// menu is open (shortcuts never register), and app-level `.commands` would
/// also fire from Settings. Capped at nine - ⌘0 reads as "reset".
private struct HostSwitchShortcuts: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if model.hosts.count > 1 {
            ForEach(Array(model.hosts.prefix(9).enumerated()), id: \.element.id) { index, host in
                Button("") { model.selectHost(host) }
                    .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")), modifiers: .command)
                    .opacity(0)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }
}

// MARK: - Connect surface

private struct ConnectSurface: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    /// True while we're between "user pressed Stream" and "stream window
    /// fades in" - the RAW connecting edge. `streamPhase == .connecting` is
    /// the whole condition (`isStreaming` must NOT be a guard - it flips at
    /// stream() ENTRY as the in-flight flag, and guarding on it made the
    /// connecting UI unreachable dead code: a stuck connect showed nothing).
    /// Suppressed while the stream window is just hiding in the background -
    /// the StreamButton's "Back to stream" role owns that affordance.
    private var isConnecting: Bool {
        guard case .connecting = model.streamPhase else { return false }
        guard !model.nativeStreamBackgrounded else { return false }
        return true
    }

    /// The VISIBLE connecting state, held back 400 ms behind the raw edge
    /// (the `.task(id: isConnecting)` below). A fast LAN connect comes up
    /// inside the hold and shows NOTHING - no spinner flash, no button morph
    /// - while a genuinely slow path gets the calm single-capsule treatment.
    @State private var showsConnectingUI = false

    /// True once the stream is established and the fullscreen window is
    /// taking over - Glimmer's window fades down so the handoff doesn't
    /// strobe two competing surfaces. NOT true while backgrounded (the
    /// launcher is the foreground surface then) and NOT during CONNECTING:
    /// `isStreaming` flips at stream() ENTRY, so without that exemption the
    /// `!isHandedOff` guard below unmounted the StreamButton for the whole
    /// handshake - the .connecting capsule was unreachable dead code and a
    /// stuck connect stranded the user on a dimmed, button-less launcher.
    /// Handoff (and the dim) now begin at the live edge, as documented.
    private var isHandedOff: Bool {
        guard model.isStreaming, !model.nativeStreamBackgrounded else { return false }
        if case .connecting = model.streamPhase { return false }
        return true
    }

    var body: some View {
        VStack(spacing: 16) {
            // Banner sits above the hero so it can't be missed. NOT behind
            // the 400 ms hold: errors must surface the instant they exist.
            ConnectBanner()
                .padding(.horizontal, 4)

            HostHero(host: model.selectedHost)
                .scaleEffect((showsConnectingUI && !reduceMotion) ? 1.04 : 1.0)
                .animation(.snappy(duration: 0.35, extraBounce: 0.1), value: showsConnectingUI)

            // Spec chips stay put during connect. The StreamButton below
            // morphs into the calm "Connecting to <host>... / stage" capsule -
            // the ONE connecting surface (a separate phase line would flash
            // duplicate affordances on fast connects).
            SpecChipsRow()

            // Hide the StreamButton entirely while the stream window owns
            // the foreground - a disabled "Streaming..." button would just
            // duplicate the stream window's presence and compete for visual
            // weight against the dimmed hero. (Connecting is NOT handed off,
            // so the capsule below stays mounted through the handshake.)
            if !isHandedOff {
                StreamButton(isConnecting: showsConnectingUI)
                    .frame(maxWidth: 380)
                    .padding(.top, 2)
                    .transition(.opacity)
            }

            ContextFooter()

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 32)
        .padding(.vertical, 20)
        // Hand off to the stream window: dim Glimmer's content so the
        // fullscreen surface visibly takes over and reverses on disconnect.
        .opacity(isHandedOff ? 0.4 : 1.0)
        .animation(.snappy(duration: 0.4), value: isHandedOff)
        // The 400 ms connect threshold. task(id:) restarts on every raw-edge
        // flip: a connect that establishes inside the hold cancels the sleep
        // (no flash); a disconnect mid-hold resets the same way.
        .task(id: isConnecting) {
            guard isConnecting else {
                showsConnectingUI = false
                return
            }
            try? await Task.sleep(nanoseconds: 400_000_000)
            if !Task.isCancelled {
                showsConnectingUI = true
                // Ground truth for the connect-hold adjudication INFO at the
                // live edge ("capsule shown" vs "suppressed") - reported from
                // the actual flip, not inferred from the span.
                model.noteConnectCapsuleShown()
            }
        }
        // Keep the route glyph pointed at the selected host's CURRENT
        // address - keyed on the resolved address, NOT selectedHost?.id:
        // re-pairing after a DHCP move rewrites the address under the SAME
        // uuid, so an id-keyed task never re-fired (glyph watched a dead IP).
        .task(id: model.selectedHostRouteAddress) {
            model.refreshHostRoute()
        }
    }
}

/// Dim contextual footer. Previously read "Ready · last played 2h ago", but
/// "Ready" now lives on the HostHero `ReadinessChip` (alongside RTT and the
/// live host state), so the footer just shows the last-played hint to avoid
/// repeating the same word twice in a single glance. The host's reported
/// version, when known, shows here as a footnote-weight breadcrumb - Apple's
/// first-party pattern (System Settings → About) of surfacing version subtly.
private struct ContextFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let host = model.selectedHost
        let parts: [String] = {
            var segments: [String] = []
            // `lastPlayedDescription` is already lowercase at the source
            // (see Host.swift) - sentence-case relative-time per macOS HIG.
            if let lp = host?.lastPlayedDescription { segments.append(lp) }
            if let version = model.hostLiveStatus?.sunshineVersion,
               !version.isEmpty, host != nil {
                // Leading Major.Minor.Patch of /serverinfo's appversion -
                // both products emit a long GFE-shaped string ("7.1.431.0").
                let short = version.split(separator: ".").prefix(3).joined(separator: ".")
                // Product-NEUTRAL copy, deliberately: GFE hosts report this
                // field too, and nothing the launcher holds can prove which
                // product sent it (Sunshine mimics GFE's appversion and
                // GfeVersion; the one discriminator - "MJOLNIR" in <state> -
                // is stream-side and never persisted). "Sunshine <ver>"
                // mislabeled every GFE host, so brand neither.
                segments.append("host version \(short)")
            }
            return segments
        }()
        if !parts.isEmpty {
            Text(parts.joined(separator: " · "))
                .font(.footnote)
                .foregroundStyle(.tertiary)
        } else {
            EmptyView()
        }
    }
}

/// Tip-style banner above the hero card. Shows for stream errors. Stays out
/// of the way otherwise.
private struct ConnectBanner: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            // The "stream is in the background" affordance lives on the
            // StreamButton itself ("Back to stream" role), so the banner only
            // handles the load-bearing recovery case: stream errors.
            if let err = model.nativeStreamError, !err.isEmpty {
                HStack(alignment: .center, spacing: 12) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 16, weight: .bold))
                        .symbolRenderingMode(.hierarchical)
                        .foregroundStyle(.red)
                    Text(err)
                        .textSelection(.enabled)
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                        .multilineTextAlignment(.leading)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Retry") {
                        model.nativeStreamError = nil
                        // The hero verb's target, NOT streamDefaultApp(): the
                        // failed launch stamped lastPlayedApp at start, so the
                        // hero above still reads "Stream <app>" - a Retry that
                        // launched the default app would contradict it.
                        model.streamHeroApp()
                    }
                    .buttonStyle(.glass)
                    .controlSize(.small)
                    .disabled(model.selectedHost == nil || model.isStreaming)
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 10)
                // Liquid Glass floating-panel chrome with the red stroke on
                // top - the stroke is the load-bearing severity affordance.
                .glassEffect(
                    .regular.tint(Color.red.opacity(0.12)),
                    in: .rect(cornerRadius: 12)
                )
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(Color.red, lineWidth: 1)
                }
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(.snappy(duration: 0.3, extraBounce: 0.1), value: model.nativeStreamError)
    }
}

/// Combined toolbar pill - host dropdown left, Settings gear right, grouped
/// via `ControlGroup`, which picks up the macOS 26 Liquid Glass toolbar
/// material and renders one segmented pill with a hairline divider.
private struct HostAndSettingsPill: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ControlGroup {
            Menu {
                ForEach(model.hosts) { host in
                    Button {
                        model.selectHost(host)
                    } label: {
                        if host.id == model.selectedHost?.id {
                            Label(host.displayName, systemImage: "checkmark")
                        } else {
                            Text(host.displayName)
                        }
                    }
                }
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "display")
                        .symbolRenderingMode(.hierarchical)
                    Text(model.selectedHost?.displayName ?? "Choose PC")
                        .lineLimit(1)
                }
            }
            Button {
                openSettings()
            } label: {
                Image(systemName: "gearshape")
                    .symbolRenderingMode(.hierarchical)
            }
            .keyboardShortcut(",", modifiers: .command)
            .help("Settings")
        }
    }
}

/// Three-stop accent gradient shared by the hero card (ContentView) and the
/// Stream button (ContentViewSubviews) - internal, not file-private - so the
/// two surfaces read as a matched pair. Top-left lifts toward white,
/// bottom-right deepens toward black; opacities stay low so the Liquid Glass
/// material dominates and the accent reads as a tint rather than a fill.
@MainActor
var accentSurfaceGradient: LinearGradient {
    LinearGradient(
        stops: [
            // Saturation matched to the Eclipse app icon (the old
            // 0.16-0.30 opacities read dull next to it).
            .init(color: Color.accentColor.mix(with: .white, by: 0.12).opacity(0.55), location: 0),
            .init(color: Color.accentColor.opacity(0.38), location: 0.55),
            .init(color: Color.accentColor.mix(with: .black, by: 0.25).opacity(0.45), location: 1.0)
        ],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
}

private struct HostHero: View {
    let host: Host?
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack(alignment: .topLeading) {
            // Background: Liquid Glass with a host-stable accent tint (hue
            // stable per name) - multi-PC households get visual continuity
            // per machine while the OS handles refraction / EDR composition.
            // `.regular.tint(...)` keeps the translucent material reading
            // correctly across light + dark mode without hardcoded RGB fights.
            RoundedRectangle(cornerRadius: 26, style: .continuous)
                .fill(accentSurfaceGradient)
                .glassEffect(
                    .regular.tint(Color.accentColor.opacity(0.22)),
                    in: .rect(cornerRadius: 26)
                )
                .overlay {
                    // Faint top-edge gloss - softened so the accent reads
                    // as material rather than a neon border.
                    RoundedRectangle(cornerRadius: 26, style: .continuous)
                        .stroke(
                            LinearGradient(
                                colors: [
                                    Color.white.opacity(0.08),
                                    Color.white.opacity(0.02)
                                ],
                                startPoint: .top, endPoint: .bottom
                            ),
                            lineWidth: 0.5
                        )
                }
                .shadow(color: .black.opacity(0.22), radius: 22, x: 0, y: 10)

            // Top-left readiness chip
            ReadinessChip()
                .padding(14)
                // Luna gate re-evaluation rides the always-present chip (the
                // power cluster renders NOTHING un-gated, so it can't
                // bootstrap itself). Keyed on the POLL TICK, not just the host
                // id, so the gate self-heals every ~10s poll - the 60s device
                // TTL bounds actual luna spawns to ~1/min; revocation vanishes
                // the controls here or on app-foreground.
                .task(id: "\(host?.id ?? "")|\(model.hostLiveStatus?.capturedAt.timeIntervalSinceReferenceDate ?? 0)") {
                    guard let host else { return }
                    await LunaPower.shared.reevaluate(for: host, model: model)
                }

            // Top-right Luna power cluster (renders nothing unless the hard
            // gate passes - see HostPowerControls / docs/LUNA_POWER.md).
            HostPowerControls()
                .padding(14)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)

            // Centered content
            VStack(spacing: 12) {
                Image(systemName: "display")
                    .font(.system(size: 42, weight: .regular))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.white.opacity(0.92))
                    .shadow(color: .black.opacity(0.30), radius: 10, x: 0, y: 2)
                    // No pulse: while a stream is foreground the hero is
                    // occluded - a pulse would burn CPU on unseen pixels.

                Text(host?.displayName ?? "No PC selected")
                    .font(.system(size: 34, weight: .bold))
                    .tracking(-0.5)
                    .foregroundStyle(.primary)
                // No last-played line here: ContextFooter is its single
                // source (both read glimmer.lastConnected, stamped at stream
                // END - the hero copy used to duplicate it AND disagree).

                if let host, !host.apps.isEmpty {
                    AppIconsRow(apps: host.apps, host: host)
                        .padding(.top, 6)
                }
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 22)
            .padding(.horizontal, 24)
        }
        // 248pt (was 270): content measures ~218pt, so this trims the hero's
        // dead air ("a bit too much") while keeping honest breathing room.
        .frame(height: 248)
        .frame(maxWidth: 520)
        // Right-click the hero to rename / set codec / unpair the current PC.
        .modifier(OptionalHostContextMenu(host: host))
    }
}

/// Applies the shared host right-click menu only when a host is selected
/// (the hero shows an empty state otherwise).
private struct OptionalHostContextMenu: ViewModifier {
    let host: Host?
    func body(content: Content) -> some View {
        if let host {
            content.hostContextMenu(host)
        } else {
            content
        }
    }
}

// NOTE: the readiness chip's composite-status model now lives with
// `ReadinessChip` in ContentViewSubviews.swift (pointer kept on purpose).

// MARK: - Menu bar content

struct MenuBarContent: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Group {
            // Icon-forward, sectioned layout within `.menu`-style MenuBarExtra
            // constraints (system NSMenu: Labels show their SF Symbol,
            // Sections render titled groups, custom materials are NOT
            // honoured - lean on iconography + structure, not glass). Item
            // order: navigational ("Open Glimmer") FIRST, then stream actions,
            // then app-wide (Settings / Quit) - Apple's first-party agent
            // pattern (Time Machine, Bluetooth).
            Button {
                openWindow(id: "main")
                activate()
            } label: {
                Label("Open Glimmer", systemImage: "macwindow")
            }

            if let host = model.selectedHost {
                Section("Connected to \(host.displayName)") {
                    Button {
                        model.streamDefaultApp()
                        activate()
                    } label: {
                        Label("Stream \(model.defaultAppName)", systemImage: "play.fill")
                    }
                    .disabled(model.isStreaming)

                    if model.hosts.count > 1 {
                        Menu {
                            ForEach(model.hosts) { host in
                                Button {
                                    model.selectHost(host)
                                } label: {
                                    if host.id == model.selectedHost?.id {
                                        Label(host.displayName, systemImage: "checkmark")
                                    } else {
                                        Text(host.displayName)
                                    }
                                }
                            }
                        } label: {
                            Label("Switch PC", systemImage: "desktopcomputer")
                        }
                    }
                }
            } else {
                Section {
                    Label("No PC paired", systemImage: "desktopcomputer.trianglebadge.exclamationmark")
                }
            }

            // Controller battery charm - shown whenever a pad reporting battery
            // is connected to the Mac (sampled on menu open).
            if let battery = model.menuBarControllerBattery {
                Section("Controller") {
                    Label(
                        "\(battery.percent)% battery\(battery.charging ? " · charging" : "")",
                        systemImage: battery.charging ? "battery.100.bolt" : "gamecontroller"
                    )
                }
            }

            Divider()

            Button {
                openSettings()
                activate()
            } label: {
                Label("Settings...", systemImage: "gearshape")
            }
            .keyboardShortcut(",")

            #if canImport(Sparkle)
            // The menu-bar dropdown is the reliable surface for the accessory
            // (no-window) case, where the app menu's "Check for Updates..." isn't
            // visible. `activate()` brings Glimmer forward so Sparkle's panel shows.
            Button {
                UpdaterController.shared.updater.checkForUpdates()
                activate()
            } label: {
                Label("Check for Updates...", systemImage: "arrow.triangle.2.circlepath")
            }
            #endif

            Button {
                NSApp.terminate(nil)
            } label: {
                Label("Quit Glimmer", systemImage: "power")
            }
            .keyboardShortcut("q")
        }
    }

    private func activate() {
        // NSApp.activate() is the macOS 14+ replacement for
        // activate(ignoringOtherApps:) - the OS decides foreground policy
        // system-side now, so the "ignoringOtherApps: true" knob is gone.
        NSApp.activate()
    }
}

// MARK: - Shared per-host right-click menu

/// Right-click actions for a paired host (Rename / Codec / Unpair),
/// shared by the launcher hero and the Settings PCTile. Right-click is the
/// canonical affordance (no visible button). Carries its own confirmation
/// dialogs + rename alert; apply via `.hostContextMenu(host)` with the
/// AppModel in the environment.
private struct HostContextMenu: ViewModifier {
    let host: Host
    @Environment(AppModel.self) private var model
    @State private var showUnpairConfirm = false
    @State private var showRename = false
    @State private var draftName = ""
    @State private var codecPref: HostCodecPreference

    init(host: Host) {
        self.host = host
        _codecPref = State(initialValue: HostCodecPreference.load(for: host.id))
    }

    func body(content: Content) -> some View {
        content
            // Make the WHOLE frame (incl. padding) right-clickable; keep the
            // secondary click out of any interactive-glass press underneath.
            .contentShape(Rectangle())
            .contextMenu {
                Button {
                    draftName = host.customName ?? ""
                    showRename = true
                } label: {
                    Label("Rename...", systemImage: "pencil")
                }
                // Per-host codec cap. Automatic negotiates AV1 → HEVC → H.264
                // against what this host's encoder supports, so the override
                // exists only for the host whose preferred codec misbehaves -
                // hence a submenu here, not a Quality-pane item.
                Picker(selection: $codecPref) {
                    ForEach(HostCodecPreference.allCases) { pref in
                        Text(pref.displayName).tag(pref)
                    }
                } label: {
                    Label("Codec", systemImage: "film.stack")
                }
                .pickerStyle(.menu)
                // Two surfaces mount this menu; reload at present-time so a
                // change on one is reflected in the other's checkmark.
                .onAppear { codecPref = HostCodecPreference.load(for: host.id) }
                .onChange(of: codecPref) { _, newValue in
                    HostCodecPreference.save(newValue, for: host.id)
                    // Spec chip/summary read the codec via UserDefaults; bump
                    // the observable sentinel so SwiftUI recomputes the Mbps.
                    model.displayInfoRevision &+= 1
                }
                Divider()
                Button(role: .destructive) {
                    showUnpairConfirm = true
                } label: {
                    Label("Unpair...", systemImage: "minus.circle")
                }
            }
            .alert("Rename \(host.name)", isPresented: $showRename) {
                TextField("Display name", text: $draftName)
                Button("Save") { model.renameHost(host, to: draftName) }
                Button("Use default name", role: .destructive) {
                    model.renameHost(host, to: "")
                }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Shown in the launcher and PC list. Leave empty (or 'Use default name') to show the PC's own hostname.")
            }
            .confirmationDialog(
                "Unpair \(host.displayName)?",
                isPresented: $showUnpairConfirm,
                titleVisibility: .visible
            ) {
                Button("Unpair", role: .destructive) { model.unpair(host) }
                Button("Cancel", role: .cancel) { }
            } message: {
                Text("Glimmer will forget this PC and leave a clean state. You can pair again at any time.")
            }
    }
}

extension View {
    /// Attach the shared per-host right-click menu (Rename / Codec / Unpair).
    func hostContextMenu(_ host: Host) -> some View {
        modifier(HostContextMenu(host: host))
    }
}
