import SwiftUI
import AppKit

// MARK: - Main Window

/// The takeover dialog's title. App names show exactly as typed ("iRacing");
/// only the lowercase "another app" fallback (AppModel+Streaming.swift) is
/// capitalized to start the sentence.
enum TakeoverDialogCopy {
    static func title(occupantApp: String, hostName: String) -> String {
        let app = occupantApp == "another app" ? "Another app" : occupantApp
        return "\(app) is running on \(hostName)."
    }
}

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings
    @State private var showAWDLPrompt = false
    @State private var awdlPromptChecked = false
    /// Lifted out of EmptyPairingState so the sheet survives the swap to
    /// ConnectSurface the instant pairing fills `model.hosts` - the sheet used
    /// to hang off the empty state itself and vanish mid-handshake success.
    @State private var showPair = false

    var body: some View {
        @Bindable var model = model
        return Group {
            if model.hosts.isEmpty {
                EmptyPairingState(showPair: $showPair)
            } else {
                ConnectSurface()
            }
        }
        .sheet(isPresented: $showPair) {
            PairSheet().environment(model)
        }
        // One-time proactive offer when a DualSense is connected (see
        // maybeOfferRawHID) - explains the feature before macOS's Input
        // Monitoring prompt; declining never re-asks.
        .alert("Turn on Extra DualSense buttons?", isPresented: $model.showRawHIDPrompt) {
            Button("Turn On") { model.enableRawHIDFromPrompt() }
            // "Not Now" just dismisses - no permanent flag - so a future
            // DualSense connect offers again. Only "Don't Ask Again" answers
            // for good (matches AWDLEnablePrompt's Not Now / Don't ask again
            // split). declineRawHIDPrompt() already sets the permanent flag.
            Button("Not Now", role: .cancel) { model.showRawHIDPrompt = false }
            Button("Don't Ask Again") { model.declineRawHIDPrompt() }
        } message: {
            Text(AppModel.rawHIDExplanation)
        }
        // Same explanation and answers for a pad macOS doesn't recognise (generic HID).
        .alert("Use \(model.hidPermissionPadName ?? "this controller") with Glimmer?",
               isPresented: $model.showHIDPermissionPrompt) {
            Button("Continue") { model.continueHIDPermission() }
            Button("Not Now", role: .cancel) { model.dismissHIDPermission() }
            Button("Don't Ask Again") { model.declineHIDPermission() }
        } message: {
            Text(AppModel.hidPermissionExplanation)
        }
        // One-time launch nudge to enable Wi-Fi stutter protection. Only for
        // users who've paired a PC (skips first-run onboarding), never while the
        // rawHID prompt is up; "Don't ask again" inside silences it for good.
        .sheet(isPresented: $showAWDLPrompt) {
            AWDLEnablePrompt(manager: AWDLHelperManager.shared)
        }
        // Pair a PC… and Pair Again… from the menu bar land here.
        .sheet(isPresented: Binding(get: { model.pairSheetAddress != nil },
                                    set: { if !$0 { model.pairSheetAddress = nil } })) {
            PairSheet(initialAddress: model.pairSheetAddress ?? "").environment(model)
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
                  !model.showRawHIDPrompt, !model.showHIDPermissionPrompt,
                  model.hostRoute.routeClass != .wired,
                  AWDLHelperManager.shared.shouldPromptToEnable else { return }
            showAWDLPrompt = true
        }
        // No .frame: forcing either axis to .infinity gives the window an
        // unbounded box to fill, and the only thing available to fill it with is
        // nothing. The content states its own size; the window follows it.
        .overlay(alignment: .top) {
            // Disconnect-beat toast - a brief, calm acknowledgement after a
            // stream ends instead of the launcher just snapping back.
            StreamEndedToast()
                .padding(.top, 16)
        }
        // Takeover confirmation: launching while an app is already running on
        // the PC quits it (unsaved progress included), so confirm first. The
        // title carries the specifics; the message states the consequence.
        .confirmationDialog(
            model.pendingTakeover.map {
                TakeoverDialogCopy.title(occupantApp: $0.occupantApp, hostName: $0.host.displayName)
            } ?? "",
            isPresented: Binding(
                get: { model.pendingTakeover != nil },
                set: { if !$0 { model.pendingTakeover = nil } }
            ),
            titleVisibility: .visible,
            presenting: model.pendingTakeover
        ) { _ in
            Button("Quit and Stream", role: .destructive) { model.confirmPendingTakeover() }
            Button("Cancel", role: .cancel) { model.pendingTakeover = nil }
        } message: { _ in
            Text("It will quit and your stream will start.")
        }
        .background {
            // ⌘1-⌘9 host switching (multi-PC households only) - invisible,
            // window-scoped. See HostSwitchShortcuts for why hidden buttons
            // beat toolbar-menu shortcuts or app-level .commands here.
            HostSwitchShortcuts()
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

    /// The raw connecting edge: `streamPhase` alone, since `isStreaming` flips at
    /// stream() entry and would hide a stuck connect. Off while the stream window
    /// only hides in the background, where Back to Stream takes over.
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

    /// The re-pair sheet behind the banner's Pair Again and the Trust needed
    /// chip, owned here because this view stays mounted while the banner
    /// empties itself on the same click.
    @State private var showRePair = false

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
            ConnectBanner(showRePair: $showRePair)
                .padding(.horizontal, 4)

            HostHero(host: model.selectedHost, showRePair: $showRePair)
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
        }
        // No trailing Spacer. It existed to pin the column to the top of a
        // window that could be taller than its content - and the space it pushed
        // down into was the empty area under the footer. The window now sizes to
        // this column (see .windowResizability in GlimmerApp), so there is no
        // leftover height to absorb and nothing to pin against.
        // 80pt sides -> a 680pt window around the 520pt card. Bisected between
        // two values checked on screen: 32 (584 window) read as cramped, the
        // card nearly touching the frame; 130 (780, matching 7.7's default
        // width) read as too big. The VERTICAL padding stays tight - the space
        // under the footer was the part that read as waste, and 7.7's own top
        // margin was 20.
        //
        // This is THE margin dial. It must stay in step with GlimmerApp's
        // window minWidth (520 + 2x this): a floor below the real content width
        // leaves the window a range to be dragged through, which is how the
        // margins got squeezed flat once already.
        .padding(.horizontal, 80)
        .padding(.vertical, 20)
        // TAKE THE IDEAL HEIGHT, NOT THE OFFERED ONE. Removing the Spacer was
        // not enough on its own: StreamButton's label carries
        // `.frame(maxWidth: .infinity, minHeight: 46)`, and a minHeight is a
        // FLOOR - the button will accept any height it is offered, which made
        // this column vertically flexible and gave the window something to grow
        // into. That is why 2026.8.2 still resized vertically. `fixedSize`
        // proposes nil height to the column, so every such floor resolves to its
        // own ideal instead of springboarding off the window.
        .fixedSize(horizontal: false, vertical: true)
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
        // Pre-filled so a re-pair lands straight on the PIN step.
        .sheet(isPresented: $showRePair) {
            let host = model.selectedHost
            PairSheet(initialAddress: host?.localAddress ?? host?.manualAddress ?? "", initialName: host?.displayName)
                .environment(model)
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
                segments.append("PC version \(short)")
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

/// Combined toolbar pill - host dropdown left, Settings gear right, grouped
/// via `ControlGroup`, which picks up the macOS 26 Liquid Glass toolbar
/// material and renders one segmented pill with a hairline divider.
private struct HostAndSettingsPill: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        ControlGroup {
            // macOS 27 hides a plain systemImage Label inside a menu item, so
            // a hand-rolled checkmark no longer marks the selection. An
            // inline Picker gets the native selection checkmark for free.
            Menu {
                Picker("PC", selection: Binding(
                    get: { model.selectedHost?.id },
                    set: { id in
                        guard let id, let host = model.hosts.first(where: { $0.id == id }) else { return }
                        model.selectHost(host)
                    }
                )) {
                    ForEach(model.hosts) { host in
                        Text(host.displayName).tag(Optional(host.id))
                    }
                }
                .pickerStyle(.inline)
                .labelsHidden()
            } label: {
                HStack(spacing: 6) {
                    Image(systemName: "display")
                        .symbolRenderingMode(.hierarchical)
                    Text(model.selectedHost?.displayName ?? "Choose a PC")
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
    @Binding var showRePair: Bool
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

            // Top-leading readiness chip: reachability, activity, and the
            // re-pair affordance for a changed host certificate.
            ReadinessChip(showRePair: $showRePair)
                .padding(14)

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
        // `width`, not `maxWidth`: the window is sized from this column, and a
        // maxWidth has no size of its own to measure - which is why an earlier
        // attempt at a content-sized window stayed resizable anyway. 520 is the
        // width the card already had in every window wide enough to show it.
        .frame(width: 520)
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
// `ReadinessChip` in ContentView+ReadinessChip.swift, the menu-bar dropdown and
// the shared per-host right-click menu in ContentView+Menus.swift, and the
// morphing hero button in ContentView+StreamButton.swift (pointers kept on
// purpose).
