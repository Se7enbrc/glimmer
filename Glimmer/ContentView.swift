import SwiftUI
import AppKit

// MARK: - Main Window

/// The takeover question, in the launcher's dialog and the menu bar's alert.
/// App names show exactly as typed ("iRacing"); nil is an app the PC didn't name.
enum TakeoverDialogCopy {
    static func title(occupantApp: String?, hostName: String) -> String {
        "\(occupantApp ?? "Another app") is running on \(hostName)."
    }

    static let message = "It will quit and your stream will start."
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
        .onAppear { model.setHIDDiscovery(true, for: .launcher) }
        .onDisappear { model.setHIDDiscovery(false, for: .launcher) }
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
        // Pair a PC… from the menu bar, and Pair Again… from the menu bar, the
        // Stream button, the banner and the Trust needed chip land here.
        .sheet(isPresented: $model.pairSheetShown) {
            PairSheet(repairing: model.pairSheetHost).environment(model)
        }
        .task {
            guard !awdlPromptChecked else { return }
            awdlPromptChecked = true
            // Let the window and route settle before deciding whether the
            // Wi-Fi helper offer applies.
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
            Text(TakeoverDialogCopy.message)
        }
        .toolbar {
            // The PC switcher is the header's name; the toolbar keeps only Settings,
            // on the trailing edge (a hidden title bar has no title to push it there).
            ToolbarSpacer(.flexible)
            ToolbarItem(placement: .automatic) {
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
        .navigationTitle("Glimmer")
    }
}

/// The Stream menu: the launcher's verbs where ⌘? finds them, and the PCs on ⌘1-⌘9
/// (nine at most; ⌘0 reads as reset). PCs lock while streaming, since ⌘ stays with the Mac.
struct StreamMenu: View {
    let model: AppModel

    var body: some View {
        if case .stream(let app) = model.menuBarPrimaryAction {
            Button("Stream \(app)") { model.streamHeroApp() }
        } else {
            Button("Stream") {}.disabled(true)
        }
        Toggle("Mini Player", isOn: Binding(get: { model.isMiniPlayer }, set: { _ in model.toggleMiniPlayer() }))
            .disabled(!model.isStreaming)
        Button("Stop Streaming") { model.stopStreamFromMenu(source: "the Stream menu") }
            .disabled(!model.isStreaming || model.menuStopInProgress)
        if !model.hosts.isEmpty { Divider() }
        ForEach(Array(model.hosts.enumerated()), id: \.element.id) { index, host in
            Toggle(host.displayName, isOn: Binding(
                get: { model.selectedHost?.id == host.id }, set: { if $0 { model.selectHost(host) } }))
                .keyboardShortcut(index < 9 ? KeyboardShortcut(KeyEquivalent(Character("\(index + 1)"))) : nil)
                .disabled(model.isStreaming)
        }
    }
}

// MARK: - Connect surface

private struct ConnectSurface: View {
    @Environment(AppModel.self) private var model

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

    /// The app buttons stream, so the Stream button only appears for the states they
    /// can't show: Wake, Back to Stream, Pair Again, and a (re)connect with no button of its own.
    private var showsStateButton: Bool {
        guard !isHandedOff else { return false }
        let role = StreamButton.role(for: model.menuBarPrimaryAction,
                                     backgrounded: model.isStreaming && model.nativeStreamBackgrounded,
                                     connectingShown: showsConnectingUI)
        if role == .connecting || role == .reconnecting { return !launchIsOnAButton }
        return role != .connect && role != .noPC
    }

    /// A launch from an app button shows on that button; one from the overflow menu,
    /// the menu bar or Shortcuts keeps the Connecting… capsule as its cancel.
    private var launchIsOnAButton: Bool {
        guard let attempt = model.lastLaunchAttempt, let host = model.selectedHost,
              attempt.host.id == host.id else { return false }
        return AppIconsRow.inlineApps(host.apps).contains { $0.id == attempt.app.id }
    }

    var body: some View {
        // The window is the object: frosted glass holding the PC, its apps and, when
        // needed, the state button. Violet is only where you act.
        VStack(alignment: .leading, spacing: 16) {
            // Banner first so it can't be missed. NOT behind the 400 ms hold:
            // errors must surface the instant they exist.
            ConnectBanner()
            PCHeader(host: model.selectedHost)
            if let host = model.selectedHost, !host.apps.isEmpty {
                AppIconsRow(apps: host.apps, host: host, connectingShown: showsConnectingUI)
            }
            if showsStateButton {
                StreamButton(isConnecting: showsConnectingUI)
                    .transition(.opacity)
            }
            ContextFooter()
                .frame(maxWidth: .infinity)
        }
        .animation(.snappy(duration: 0.3), value: showsStateButton)
        // No trailing Spacer: the window sizes to this column (.windowResizability
        // in GlimmerApp). 532pt of content in 24pt margins is the 580pt window, and
        // must stay in step with GlimmerApp's minWidth, or the window can be dragged.
        .frame(width: 532)
        .padding(.horizontal, 24)
        .padding(.top, 4)
        .padding(.bottom, 18)
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
    }
}

/// One quiet line at the bottom: when this PC was last played. "Ready" lives
/// on the readiness chip, so the footer never repeats it.
private struct ContextFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        if let lastPlayed = model.selectedHost?.lastPlayedDescription {
            Text(lastPlayed)
                .font(.footnote)
                .foregroundStyle(.tertiary)
        }
    }
}

/// The primary controls' surface: the accent lifted toward white at the top left and
/// deepened at the bottom right, opaque, so the app buttons and Stream are the violet on screen.
@MainActor
var accentSurfaceGradient: LinearGradient {
    LinearGradient(colors: [Color.accentColor.mix(with: .white, by: 0.10), Color.accentColor.mix(with: .black, by: 0.18)],
                   startPoint: .topLeading, endPoint: .bottomTrailing)
}

/// The PC as the launcher's title: its name (the switcher, when there is more than
/// one PC), the specs under it and the readiness chip. Right-click for the PC's menu.
private struct PCHeader: View {
    let host: Host?
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "display")
                .font(.system(size: 30))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                if model.hosts.count > 1 { switcher } else { name }
                SpecChipsRow()
            }
            Spacer(minLength: 12)
            // Reachability, activity, and the re-pair affordance for a
            // changed certificate; last played stays in ContextFooter.
            ReadinessChip()
        }
        .modifier(OptionalHostContextMenu(host: host))
    }

    private var name: some View {
        Text(host?.displayName ?? "No PC selected")
            .font(.title.weight(.semibold))
            .lineLimit(1)
    }

    /// The name opens the PC list. An inline Picker gives the native checkmark,
    /// which macOS 27 no longer draws for a plain symbol in a menu item.
    private var switcher: some View {
        Menu {
            Picker("PC", selection: Binding(
                get: { model.selectedHost?.id },
                set: { id in
                    guard let id, let pick = model.hosts.first(where: { $0.id == id }) else { return }
                    model.selectHost(pick)
                }
            )) {
                ForEach(model.hosts) { Text($0.displayName).tag(Optional($0.id)) }
            }
            .pickerStyle(.inline)
            .labelsHidden()
        } label: {
            HStack(spacing: 6) {
                name
                Image(systemName: "chevron.down")
                    .font(.callout.weight(.bold))
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Choose a PC")
        .accessibilityLabel("PC")
        .accessibilityValue(host?.displayName ?? "None")
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
