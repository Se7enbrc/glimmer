//
//  ContentView+StreamButton.swift
//
//  The hero's morphing primary action and the accent button style it shares
//  with the other CTAs. `.connecting`, `.reconnecting` and `.waking` are ways
//  out: they stay enabled, carry a quiet trailing label and bind ⎋.
//

import SwiftUI

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

    /// Choose a PC (disabled), Stream <app>, connecting (a cancel, so a stuck
    /// connect never strands the user), reconnecting (Stop Streaming), Back to
    /// Stream for a hidden stream window, Pair Again…, then the two wake states.
    enum ButtonRole: Equatable {
        case noPC
        case connect
        case connecting
        case reconnecting
        case liveBackgrounded
        case pairAgain
        /// PC asleep with Wake on LAN on: the hero CTA becomes the one obvious
        /// action (Wake and Connect) instead of a dead Stream button.
        case wake
        /// A wake in flight (packets sent, waiting up to 90 s for Sunshine).
        /// Like `.connecting` the capsule stays enabled and is the cancel.
        case waking
    }

    /// The menu bar's primary action, so the two never disagree. Only the launcher
    /// hides a stream window it can bring back, and a connect reads as Stream
    /// until the 400 ms hold shows the capsule.
    static func role(for action: MenuBarPrimaryAction, backgrounded: Bool, connectingShown: Bool) -> ButtonRole {
        if backgrounded { return .liveBackgrounded }
        switch action {
        case .none: return .noPC
        case .stream, .backToStream: return .connect
        case .cancelConnection: return connectingShown ? .connecting : .connect
        case .stopStreaming: return connectingShown ? .reconnecting : .connect
        case .pairAgain: return .pairAgain
        case .wake: return .wake
        case .waking: return .waking
        }
    }

    private var role: ButtonRole {
        Self.role(for: model.menuBarPrimaryAction, backgrounded: model.isStreaming && model.nativeStreamBackgrounded,
                  connectingShown: isConnecting)
    }

    /// The roles whose click ends something rather than launching. They share
    /// the ⎋ binding (Escape-to-cancel is platform muscle memory) and must never
    /// take the Return key, which users mash.
    private var isCancelRole: Bool {
        role == .connecting || role == .reconnecting || role == .waking
    }

    var body: some View {
        Button {
            switch role {
            case .noPC: break                                  // disabled - copy is the affordance
            case .connect: model.streamHeroApp()
            case .connecting: model.cancelConnect()        // the working exit from a stuck connect
            case .reconnecting: model.stopStreamFromMenu(source: "the launcher")  // a live stream, so it stops
            case .liveBackgrounded: model.resumeStreamWindow()
            case .pairAgain: model.requestPairing(for: model.selectedHost)
            case .wake:
                if let host = model.selectedHost { model.wakeHost(host, thenConnect: true) }
            case .waking:
                // The working exit from a wake that is taking too long. Drops
                // our wait only; the tile falls back to offline + Wake and a
                // fresh Wake starts clean (see AppModel.cancelWake).
                if let host = model.selectedHost { model.cancelWake(host) }
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
                case .connecting, .reconnecting:
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
                    Text(role == .reconnecting ? "Stop Streaming" : "Cancel")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
                case .liveBackgrounded:
                    Image(systemName: "play.tv.fill")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Back to Stream")
                        .font(.system(size: 17, weight: .semibold))
                        .contentTransition(.opacity)
                case .pairAgain:
                    Image(systemName: "key.fill")
                        .font(.system(size: 16, weight: .semibold))
                    Text("Pair Again…")
                        .font(.system(size: 17, weight: .semibold))
                        .contentTransition(.opacity)
                case .wake:
                    Image(systemName: "power")
                        .font(.system(size: 16, weight: .semibold))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Wake and Connect")
                            .font(.system(size: 17, weight: .semibold))
                            .contentTransition(.opacity)
                        // One line that fits; the Wake on LAN limits live in the
                        // tooltip. A cancelled wake shows nothing.
                        if let reason = wakeFailure, let host = model.selectedHost {
                            Text(Self.wakeFailureLine(reason, pcName: host.displayName))
                                .font(.system(size: 11, weight: .regular))
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                case .waking:
                    ProgressView()
                        .controlSize(.small)
                    Text("Waking \(model.selectedHost?.displayName ?? "PC")…")
                        .font(.system(size: 16, weight: .semibold))
                        .lineLimit(1)
                        .contentTransition(.opacity)
                    // Same quiet trailing affordance as the connecting capsule:
                    // the whole capsule is the cancel, so name it.
                    Text("Stop Waiting")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .padding(.leading, 4)
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
        // up). The cancel roles bind ⎋ instead - Escape-to-cancel is
        // platform muscle memory, and Return must NOT cancel (users mash it).
        .keyboardShortcut(isCancelRole ? .cancelAction : .defaultAction)
        .controlSize(.large)
        // The cancel roles stay ENABLED - they're the way out.
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
                            .labelStyle(.titleAndIcon)
                    }
                    // Same second-concurrent-session gate as the app tiles.
                    .disabled(model.isStreaming)
                }
            }
        }
        .help(guidance.help)
        // VoiceOver hint mirrors the sighted-only `.help` so assistive-tech
        // users learn WHY the button is disabled (noPC) or what a click does.
        .accessibilityHint(guidance.hint)
        .animation(.snappy(duration: 0.35, extraBounce: 0.1), value: isConnecting)
        .animation(.snappy(duration: 0.35, extraBounce: 0.1), value: model.isStreaming)
    }

    /// Tooltip and VoiceOver hint for the current role, kept in one place.
    private var guidance: (help: String, hint: String) {
        switch role {
        case .noPC: ("Pair a PC first to start streaming", "Pair a PC first to start streaming")
        case .connect: ("Right-click to choose an app", "Right-click to choose an app")
        case .connecting: ("Cancel the connection attempt", "Cancels the connection attempt")
        case .reconnecting: ("End the stream", "Ends the stream")
        case .liveBackgrounded: ("Show the stream window", "Shows the stream window")
        case .pairAgain: ("Pair again to trust this PC's new certificate", "Pairs again to trust this PC's new certificate")
        case .wake where wakeFailure == .noAnswer: (Self.wakeLimits, Self.wakeLimits)
        case .wake:
            ("Wake this PC, then connect. Right-click to choose an app.",
             "Wakes this PC, then connects. Right-click to choose an app.")
        case .waking: ("Stop waiting for this PC to wake up", "Stops waiting for this PC to wake up")
        }
    }

    private static let wakeLimits = AppModel.wakeNoAnswerHint
        + " It also has to be turned on in the PC's network adapter settings."

    /// Why the selected PC's last wake failed; nil once it is another PC's.
    private var wakeFailure: AppModel.WakeFailureReason? {
        guard let host = model.selectedHost, model.wakeFailedHostID == host.id else { return nil }
        return model.wakeFailureReason
    }

    /// The one line under Wake and Connect; it has to fit the capsule.
    static func wakeFailureLine(_ reason: AppModel.WakeFailureReason, pcName: String) -> String {
        switch reason {
        case .noAnswer: "No answer from \(pcName)."
        case .couldNotSend: reason.line
        }
    }

    private var connectingStage: String? {
        if case .connecting(let stage) = model.streamPhase { return stage }
        return nil
    }

    private var connectingPrimary: String {
        Self.connectingPrimary(stage: connectingStage, selectedName: model.selectedHost?.displayName)
    }

    private var connectingSubtext: String? {
        Self.connectingSubtext(stage: connectingStage, primary: connectingPrimary)
    }

    /// Steady primary line. Prefers the SESSION's own stage (connect, reconnect
    /// or "Cancelling…"), which names the PC it's dialling even after ⌘1-⌘9
    /// re-points `selectedHost` mid-handshake.
    static func connectingPrimary(stage: String?, selectedName: String?) -> String {
        if let stage, stage.hasPrefix("Connecting to ") || stage.hasPrefix("Reconnecting to ")
            || stage == "Cancelling…" {
            return stage
        }
        if let selectedName { return "Connecting to \(selectedName)…" }
        return "Connecting…"
    }

    /// Engine-stage subtext below the primary line, only when it adds
    /// something the primary doesn't already say ("RTSP handshake").
    static func connectingSubtext(stage: String?, primary: String) -> String? {
        guard let stage, !stage.isEmpty, stage != primary else { return nil }
        if stage.hasPrefix("Connecting to ") || stage == "Connecting…" { return nil }
        return stage
    }
}
