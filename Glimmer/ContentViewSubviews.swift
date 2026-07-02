//
//  ContentViewSubviews.swift
//
//  Host-hero presentation pieces split out of ContentView.swift: the readiness
//  chip, app-icon and spec-chip rows, the morphing Stream button, and the
//  empty-pairing / stream-ended states. Internal so ContentView.swift composes.
//

import Accessibility
import AppKit
import SwiftUI

enum ChipPresentation: Equatable {
    case noPC                                   // gray dot, "No PC"
    case ready(rttMs: Int?)                     // green dot, "Ready" / "Ready · 12 ms"
    case streamingOurs                          // pulsing green, "Streaming" (our session)
    case connecting(phase: String)              // amber dot, current handshake phase
    case streamingElsewhere(appName: String)    // blue dot, "Streaming Helldivers 2"
    case asleep                                 // dim gray dot, "Asleep"
    case certMismatch                           // amber dot, "Trust needed"
    case unknown                                // amber dot, "Checking..." (pre-first-poll)

    /// Truncated, single-line label - the chip must stay narrower than the
    /// hero, and game names can be long; we cap at 22 chars.
    var label: String {
        switch self {
        case .noPC: return "No PC"
        case .ready(nil): return "Ready"
        case .ready(let ms?): return "Ready · \(ms) ms"
        case .streamingOurs: return "Streaming"
        case .connecting(let phase):
            // Friendly strings ("Connecting to Tower...") - pass through.
            return Self.truncate(phase, to: 22)
        case .streamingElsewhere(let name):
            return "Streaming \(Self.truncate(name, to: 14))"
        case .asleep: return "Asleep"
        case .certMismatch: return "Trust needed"
        case .unknown: return "Checking..."
        }
    }

    /// The screen-reader sentence, so the chip isn't read as bare jargon.
    var accessibility: String {
        switch self {
        case .noPC: return "No PC selected"
        case .ready(nil): return "Host ready"
        case .ready(let ms?): return "Host ready, round trip \(ms) milliseconds"
        case .streamingOurs: return "Streaming"
        case .connecting(let phase): return phase
        case .streamingElsewhere(let name): return "Host is streaming \(name)"
        case .asleep: return "Host is asleep or unreachable"
        case .certMismatch: return "Host certificate changed, re-pair to trust it"
        case .unknown: return "Checking host status"
        }
    }

    var dotColor: Color {
        switch self {
        case .noPC: return Color.gray
        case .ready: return Color.green
        case .streamingOurs: return Color.green
        case .connecting: return Color.orange
        case .streamingElsewhere: return Color.blue
        case .asleep: return Color.secondary
        case .certMismatch: return Color.orange
        case .unknown: return Color.orange
        }
    }

    /// Only the "our session" beat earns a heartbeat - someone-else's session
    /// must not pulse the chip as if WE were live.
    var pulsing: Bool {
        if case .streamingOurs = self { return true }
        return false
    }

    private static func truncate(_ str: String, to max: Int) -> String {
        if str.count <= max { return str }
        let end = str.index(str.startIndex, offsetBy: max - 1)
        return str[str.startIndex..<end] + "..."
    }
}

struct ReadinessChip: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Drives the re-pair sheet the certMismatch chip opens - re-pairing is the
    /// Trust recovery (it re-pins the host's new cert). Pre-filled with the
    /// host's address so the user lands on the PIN step, not the chooser.
    @State private var showRePair = false

    /// Resolve the user-facing chip presentation. Priority order matters -
    /// our own session beats the polled host state (we'd rather show the live
    /// truth than briefly flash "Asleep" off a stale poller sample).
    private var presentation: ChipPresentation {
        // The CONNECTING phase outranks the in-flight flag: `isStreaming`
        // flips at stream() ENTRY (the in-flight latch, not the live edge),
        // so checking it first pulsed a green "Streaming" through the entire
        // handshake - including connects that never establish. Typed switch:
        // the String shim reads "Streaming" for the .streaming phase.
        if case .connecting(let stage) = model.streamPhase {
            return .connecting(phase: stage)
        }
        if model.isStreaming { return .streamingOurs }
        guard model.selectedHost != nil else { return .noPC }

        // Polled live snapshot → chip state. The host-id guard in
        // `publishLiveStatus` already scopes it to the selected host.
        guard let live = model.hostLiveStatus else { return .unknown }
        // Aged-out samples (the host stopped answering /serverinfo a while
        // back) shouldn't keep lying about a stream that ended hours ago.
        if Date().timeIntervalSince(live.capturedAt) > HostLiveStatus.stale {
            return .unknown
        }
        switch live.state {
        case .unknown:                          return .unknown
        case .idle:                             return .ready(rttMs: live.rttMs)
        case .streamingApp(let name):           return .streamingElsewhere(appName: name)
        case .streamingUnknownApp:              return .streamingElsewhere(appName: "an app")
        case .asleep:                           return .asleep
        case .certMismatch:                     return .certMismatch
        }
    }

    var body: some View {
        let chip = presentation
        // GlassEffectContainer composites adjacent glass elements as ONE
        // floating cluster (Apple's Liquid Glass guidance) instead of
        // stacking independent blur passes into double-blur artefacts.
        GlassEffectContainer(spacing: 8) {
            HStack(spacing: 8) {
                HStack(spacing: 6) {
                    Circle()
                        .fill(chip.dotColor)
                        .frame(width: 7, height: 7)
                        .symbolEffect(.pulse, options: .repeating, isActive: chip.pulsing && !reduceMotion)
                    Text(chip.label)
                        .font(.caption.weight(.medium))
                        .foregroundStyle(.primary)
                        .contentTransition(.opacity)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    // Quiet route glyph - bolt / Wi-Fi arcs - riding the
                    // ALWAYS-ON HostRouteMonitor, never the gate-on probe.
                    if case .ready = chip, let glyph = model.hostRoute.glyphSystemName {
                        Image(systemName: glyph)
                            .font(.system(size: 9, weight: .semibold))
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .glassEffect(.regular, in: .capsule)
                // certMismatch chip is the Trust affordance: a click re-pairs
                // (re-pinning the host's new cert). Inert for every other state.
                .contentShape(Capsule())
                .onTapGesture { if chip == .certMismatch { showRePair = true } }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilitySummary(for: chip))
                .accessibilityAddTraits(chip == .certMismatch ? .isButton : [])
                .accessibilityHint(chip == .certMismatch ? "Re-pair to trust the new certificate" : "")

                // HDR-active chip: only while a stream is confirmed PQ/HLG
                // end-to-end (the static SpecChipsRow tag is just the pref).
                // Intentionally NOT glass - a vivid status badge should pop
                // (Apple's HIG carves badges out of the glass-everything rule).
                if model.nativeHDRActive {
                    Text("HDR")
                        .font(.caption2.weight(.bold))
                        .tracking(0.5)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 3)
                        .background(
                            LinearGradient(
                                colors: [Color.yellow, Color.orange],
                                startPoint: .topLeading,
                                endPoint: .bottomTrailing
                            ),
                            in: Capsule()
                        )
                        .overlay(Capsule().stroke(Color.white.opacity(0.25), lineWidth: 0.5))
                        .transition(.scale.combined(with: .opacity))
                        .accessibilityLabel("HDR active")
                }
            }
        }
        .animation(.snappy(duration: 0.3, extraBounce: 0.1), value: presentation)
        .animation(.snappy(duration: 0.3, extraBounce: 0.1), value: model.nativeHDRActive)
        .animation(.snappy(duration: 0.3, extraBounce: 0.1), value: model.hostRoute.routeClass)
        .sheet(isPresented: $showRePair) {
            // Pre-fill the host's address so the re-pair lands straight on the
            // PIN step (the initialAddress path that was previously dead).
            PairSheet(initialAddress: rePairAddress).environment(model)
        }
    }

    /// Best-known address for the selected host, used to pre-fill the re-pair
    /// sheet. Empty when nothing is selected (the sheet then opens the chooser).
    private var rePairAddress: String {
        guard let host = model.selectedHost else { return "" }
        return host.localAddress ?? host.manualAddress ?? ""
    }

    /// Chip sentence + route flavour for VoiceOver ("Host ready, round trip
    /// 12 milliseconds, over Wi-Fi") - mirrors the sighted glyph's gating.
    private func accessibilitySummary(for chip: ChipPresentation) -> String {
        guard case .ready = chip,
              let route = model.hostRoute.accessibilityDescription else {
            return chip.accessibility
        }
        return "\(chip.accessibility), \(route)"
    }
}

struct AppIconsRow: View {
    let apps: [LibraryApp]
    let host: Host
    @Environment(AppModel.self) private var model

    var body: some View {
        // One glass composite for the row - see ReadinessChip's container note.
        GlassEffectContainer(spacing: 10) {
            HStack(spacing: 10) {
                ForEach(apps.prefix(4)) { app in
                    Button {
                        model.requestStream(app: app, on: host)
                    } label: {
                        VStack(spacing: 4) {
                            Image(systemName: app.systemImage)
                                .font(.system(size: 18, weight: .medium))
                                .symbolRenderingMode(.hierarchical)
                                .frame(width: 44, height: 44)
                                .glassEffect(
                                    .regular.interactive(),
                                    in: .rect(cornerRadius: 10)
                                )
                                .overlay {
                                    // Accent ring for the hero target (resume
                                    // app, else default) so the ring always
                                    // agrees with the hero button's verb.
                                    RoundedRectangle(cornerRadius: 10, style: .continuous)
                                        .stroke(
                                            app.name == model.heroTargetAppName ? Color.accentColor : Color.clear,
                                            lineWidth: 2
                                        )
                                }
                            Text(app.name)
                                .font(.caption2)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        .frame(width: 70)
                    }
                    .buttonStyle(.plain)
                    .help(model.isStreaming
                        ? "Finish the current stream first" : "Stream \(app.name)")
                }
            }
        }
        // Tiles park while a session exists (connecting, live, backgrounded):
        // a click would spawn a SECOND concurrent session - stream()'s
        // re-entrancy guard is the wall, this is the honest affordance. Dim
        // as the visual cue (.plain buttons don't restyle on disable).
        .disabled(model.isStreaming)
        .opacity(model.isStreaming ? 0.45 : 1.0)
        .animation(.snappy(duration: 0.3), value: model.isStreaming)
    }
}

struct SpecChipsRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // One glass composite for the row - see ReadinessChip's container note.
        GlassEffectContainer(spacing: 6) {
            HStack(spacing: 6) {
                ForEach(model.streamSpecChips, id: \.self) { chip in
                    Text(chip)
                        .font(.caption.weight(.medium))
                        .padding(.horizontal, 10)
                        .padding(.vertical, 4)
                        .glassEffect(.regular, in: .capsule)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }
}

/// Material-weighted accent button - same gradient + glass tint + soft rim as
/// the hero card. Sized naturally by its label so modal-sheet rows keep their
/// layout (the hero StreamButton applies its own `.frame(maxWidth:)`).
/// Internal so SettingsView's Pair/Stream-now buttons share the treatment.
struct StreamButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 17, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.horizontal, 22)
            .padding(.vertical, 12)
            .frame(minHeight: 46)
            .background {
                Capsule()
                    .fill(accentSurfaceGradient)
                    .glassEffect(
                        .regular.tint(Color.accentColor.opacity(0.25)),
                        in: .capsule
                    )
                    .overlay {
                        Capsule()
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.10),
                                        Color.white.opacity(0.02)
                                    ],
                                    startPoint: .top, endPoint: .bottom
                                ),
                                lineWidth: 0.5
                            )
                    }
                    .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 4)
            }
            .opacity(isEnabled ? 1.0 : 0.55)
            .scaleEffect(configuration.isPressed ? 0.985 : 1.0)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

struct StreamButton: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    var isConnecting: Bool = false

    /// The success haptic belongs on the actual "we're live" beat - this flag
    /// gives sensoryFeedback a precise connectionEstablished edge, not a tap.
    private var isLive: Bool {
        model.streamPhase == .streaming
    }

    /// Four button states, depending on session lifecycle and selection:
    ///   * `.noPC`        - no host paired/selected. "Choose a PC"; tap is a
    ///                       no-op, the label tells the user what to do next.
    ///   * `.connect`     - host selected, no stream yet. "Stream <app>" (the
    ///                       resume target if known - host-reported session or
    ///                       last-played - else the default app). Tap launches.
    ///   * `.connecting`  - handshake in flight. "Connecting to <Host>..." +
    ///                       stage subtext. Tap (or ⎋) CANCELS the attempt -
    ///                       a stuck connect must never strand the user.
    ///   * `.liveBackgrounded` - stream running, window hidden. Tap = "Back
    ///                       to stream".
    private enum ButtonRole {
        case noPC
        case connect
        case connecting
        case liveBackgrounded
    }
    private var role: ButtonRole {
        if isConnecting { return .connecting }
        if model.isStreaming, model.nativeStreamBackgrounded {
            return .liveBackgrounded
        }
        if model.selectedHost == nil { return .noPC }
        return .connect
    }

    var body: some View {
        Button {
            switch role {
            case .noPC: break                                  // disabled - copy is the affordance
            case .connect: model.streamHeroApp()
            case .connecting: model.cancelConnect()        // the working exit from a stuck connect
            case .liveBackgrounded: model.resumeStreamWindow()
            }
        } label: {
            HStack(spacing: 10) {
                switch role {
                case .noPC:
                    Image(systemName: "display")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Choose a PC")
                        .font(.system(size: 17, weight: .semibold))
                        .contentTransition(.opacity)
                case .connecting:
                    // Steady primary line; engine-stage churn flows through
                    // the subtext - calmer than swapping the whole label.
                    ProgressView()
                        .controlSize(.small)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(connectingPrimary)
                            .font(.system(size: 16, weight: .semibold))
                            .lineLimit(1)
                        if let stage = connectingSubtext {
                            Text(stage)
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                                .contentTransition(.opacity)
                        }
                    }
                    // The whole capsule is the cancel button - say so, quietly.
                    Text("Cancel")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                case .liveBackgrounded:
                    Image(systemName: "play.tv.fill")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Back to stream")
                        .font(.system(size: 17, weight: .semibold))
                        .contentTransition(.opacity)
                case .connect:
                    // Static play glyph + the manager's hero verb (an icon/
                    // label swap here would flash inside the 400 ms hold).
                    Image(systemName: "play.fill")
                        .font(.system(size: 16, weight: .semibold))
                        // Bounce on the live edge (curtain rises). Suppressed
                        // under Reduce Motion; the success haptic still fires.
                        .symbolEffect(.bounce, value: reduceMotion ? false : isLive)
                    Text(model.heroActionLabel)
                        .font(.system(size: 17, weight: .semibold))
                        .lineLimit(1)
                        .contentTransition(.opacity)
                }
            }
            .frame(maxWidth: .infinity, minHeight: 46)
        }
        // Custom style = the hero's accent gradient + glass + soft rim.
        // `.glassProminent` was too saturated; `.glass` near-neutral.
        .buttonStyle(StreamButtonStyle())
        // ENTER-TO-PLAY: Return fires the hero verb from anywhere in the
        // window (.disabled keeps it a no-op; sheets/alerts own Return while
        // up). The connecting capsule binds ⎋ instead - Escape-to-cancel is
        // platform muscle memory, and Return must NOT cancel (users mash it).
        .keyboardShortcut(role == .connecting ? .cancelAction : .defaultAction)
        .controlSize(.large)
        // .connecting stays ENABLED - it's the cancel affordance.
        .disabled(
            role == .noPC ||
            (role == .connect && model.isStreaming)
        )
        // Success haptic on the actual establish edge, not on click.
        .sensoryFeedback(.success, trigger: isLive)
        .contextMenu {
            if let host = model.selectedHost {
                ForEach(host.apps) { app in
                    Button {
                        model.requestStream(app: app, on: host)
                    } label: {
                        Label(app.name, systemImage: app.systemImage)
                    }
                    // Same second-concurrent-session gate as the app tiles.
                    .disabled(model.isStreaming)
                }
            }
        }
        .help(role == .noPC ? "Pair a PC first to start streaming"
            : role == .connecting ? "Cancel the connection attempt"
            : "Right-click to choose an app")
        // VoiceOver hint mirrors the sighted-only `.help` so assistive-tech
        // users learn WHY the button is disabled (noPC) or what a click does.
        .accessibilityHint(
            role == .noPC ? "Pair a PC first to start streaming"
                : role == .connecting ? "Cancels the connection attempt"
                : role == .connect ? "Right-click to choose an app" : ""
        )
        .animation(.snappy(duration: 0.35, extraBounce: 0.1), value: isConnecting)
        .animation(.snappy(duration: 0.35, extraBounce: 0.1), value: model.isStreaming)
    }

    /// Steady primary line during connect. Prefers the SESSION's own friendly
    /// stage ("Connecting to <host>..." / "Cancelling...", stamped with the host
    /// captured at stream() entry): ⌘1-⌘9 can re-point `selectedHost`
    /// mid-handshake, and the capsule must keep naming the PC it's dialling.
    private var connectingPrimary: String {
        if let stage = model.nativeStreamPhase,
           stage.hasPrefix("Connecting to ") || stage == "Cancelling..." {
            return stage
        }
        if let name = model.selectedHost?.displayName {
            return "Connecting to \(name)..."
        }
        return "Connecting..."
    }

    /// Optional engine-stage subtext below the primary line - surfaced only
    /// when the stage adds information beyond the primary ("RTSP handshake"),
    /// stripping whatever the primary already carries ("Connecting to X..."
    /// duplicates, the "Cancelling..." repaint).
    private var connectingSubtext: String? {
        guard let stage = model.nativeStreamPhase, !stage.isEmpty else { return nil }
        if stage == connectingPrimary { return nil }
        if stage.hasPrefix("Connecting to ") || stage == "Connecting..." { return nil }
        return stage
    }
}

// MARK: - Empty pairing state

struct EmptyPairingState: View {
    @Environment(AppModel.self) private var model
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showPair = false

    var body: some View {
        VStack(spacing: 26) {
            Spacer()

            ZStack {
                // Floating glass medallion behind the hero symbol -
                // accent-tinted so it picks up the system tint.
                Circle()
                    .frame(width: 144, height: 144)
                    .glassEffect(
                        .regular.tint(Color.accentColor.opacity(0.18)),
                        in: .circle
                    )
                    .overlay {
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.22),
                                        Color.white.opacity(0.04)
                                    ],
                                    startPoint: .top, endPoint: .bottom
                                ),
                                lineWidth: 1
                            )
                    }
                Image(systemName: "display.and.arrow.down")
                    .font(.system(size: 60, weight: .light))
                    .symbolRenderingMode(.hierarchical)
                    .foregroundStyle(.tint)
                    .symbolEffect(.pulse.byLayer, options: .repeating, isActive: !reduceMotion)
            }

            VStack(spacing: 10) {
                Text("Let's find your gaming PC")
                    .font(.system(size: 26, weight: .bold))
                    .tracking(-0.4)
                Text("Glimmer plays games from your gaming PC, on this Mac.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }

            Button {
                showPair = true
            } label: {
                Label("Pair a PC", systemImage: "plus.circle.fill")
                    .frame(minWidth: 260)
            }
            .buttonStyle(StreamButtonStyle())
            .controlSize(.large)

            Spacer()
        }
        .padding(40)
        .sheet(isPresented: $showPair) {
            PairSheet().environment(model)
        }
    }
}

// MARK: - Stream-ended toast (disconnect beat)

/// Brief "Stream ended" acknowledgement above the launcher content, driven
/// off `AppModel.streamEndedToastVisible`; auto-dismisses after a
/// short hold (the stream window's own fade is missable from a Cmd-Tab).
/// Thin material, no icon, monochrome - Apple's first-party toasts (AirPods
/// connect, volume HUD) are deliberately understated.
struct StreamEndedToast: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        Group {
            if model.streamEndedToastVisible {
                VStack(spacing: 2) {
                    Text("Stream ended")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.primary)
                    // Session receipt - one quiet line ("2h 12m · 12 ms
                    // median"), only when the stash kept one (≥5 min sessions).
                    if let line = model.lastSessionReceiptToastLine {
                        Text(line)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                .padding(.horizontal, 18)
                .padding(.vertical, 8)
                .background(.thinMaterial, in: Capsule())
                .overlay(Capsule().stroke(Color.primary.opacity(0.08), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.12), radius: 8, x: 0, y: 4)
                .transition(.move(edge: .top).combined(with: .opacity))
                // One element, one sentence for assistive tech.
                .accessibilityElement(children: .combine)
                // Keyed on the receipt so a back-to-back end re-arms the hold
                // for the new content; the flag reset in stream() is the other
                // half - the flag actually FALLS between cycles now, so a
                // repeat end gets a fresh task, not a half-spent hold.
                .task(id: model.lastSessionReceipt) {
                    // VoiceOver never reaches a 2-4 s transient by focus
                    // navigation - announce the beat + receipt explicitly.
                    let line = model.lastSessionReceiptToastLine
                    AccessibilityNotification.Announcement(
                        line.map { "Stream ended. \($0)" } ?? "Stream ended"
                    ).post()
                    // Auto-dismiss - 2 s plain, 4 s with the receipt line.
                    let hold: UInt64 = line == nil ? 2_000_000_000 : 4_000_000_000
                    try? await Task.sleep(nanoseconds: hold)
                    if !Task.isCancelled {
                        model.streamEndedToastVisible = false
                    }
                }
            }
        }
        .animation(.snappy(duration: 0.30, extraBounce: 0.1),
                   value: model.streamEndedToastVisible)
    }
}
