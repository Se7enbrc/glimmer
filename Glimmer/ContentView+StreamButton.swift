//
//  ContentView+StreamButton.swift
//
//  The hero's morphing primary action and the material-weighted button style it
//  shares with the other accent CTAs: the six `ButtonRole` states (choose a PC,
//  stream, connecting, back-to-stream, wake, waking) and the two roles that are
//  really CANCELS - `.connecting` and `.waking` both stay enabled, carry a quiet
//  trailing "Cancel", and bind ⎋. Split out of ContentViewSubviews.swift to keep
//  each file under the length limit.
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
        /// Host asleep + Luna power gate passed: the hero CTA becomes the one
        /// obvious action ("Wake & Connect") instead of a dead Stream button.
        case wake
        /// luna's synchronous wake in flight (~36s cold, capped at 200s). Like
        /// `.connecting` the capsule stays ENABLED and IS the cancel: a wait
        /// that long with no way out is a dead end, and abandoning it costs
        /// nothing (UpSnap already has the request - see AppModel.cancelWake).
        case waking
    }
    private var role: ButtonRole {
        if isConnecting { return .connecting }
        if model.isStreaming, model.nativeStreamBackgrounded {
            return .liveBackgrounded
        }
        guard let host = model.selectedHost else { return .noPC }
        if LunaPower.shared.gatedDevice(for: host) != nil {
            if LunaPower.shared.actionInFlight[host.id] == "on" { return .waking }
            if hostIsAsleep(host), LunaPower.shared.actionInFlight[host.id] == nil {
                return .wake
            }
        }
        return .connect
    }

    /// The two roles whose click is a cancel, not a launch. They share the ⎋
    /// binding (Escape-to-cancel is platform muscle memory) and must never take
    /// the Return key, which users mash.
    private var isCancelRole: Bool {
        role == .connecting || role == .waking
    }

    /// Fresh polled truth says the selected host is asleep (mirrors the
    /// readiness chip's staleness rules).
    private func hostIsAsleep(_ host: Host) -> Bool {
        guard let live = model.hostLiveStatus, live.hostID == host.id,
              Date().timeIntervalSince(live.capturedAt) <= HostLiveStatus.stale else {
            return false
        }
        if case .asleep = live.state { return true }
        return false
    }

    var body: some View {
        Button {
            switch role {
            case .noPC: break                                  // disabled - copy is the affordance
            case .connect: model.streamHeroApp()
            case .connecting: model.cancelConnect()        // the working exit from a stuck connect
            case .liveBackgrounded: model.resumeStreamWindow()
            case .wake:
                if let host = model.selectedHost,
                   let device = LunaPower.shared.gatedDevice(for: host) {
                    model.wakeHost(host, device: device, thenConnect: true)
                }
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
                case .wake:
                    Image(systemName: "bolt.fill")
                        .font(.system(size: 16, weight: .semibold))
                    VStack(alignment: .leading, spacing: 1) {
                        Text("Wake & Connect")
                            .font(.system(size: 17, weight: .semibold))
                            .contentTransition(.opacity)
                        // A failed wake surfaces one plain sentence here, right
                        // under the retry affordance - luna's raw reason (subprocess
                        // stderr, "on failed", "luna not available") stays in the
                        // log (see AppModel+Power.swift's Diag.notice) and is never
                        // shown to the user verbatim. A CANCELLED wake records no
                        // error, so this line stays away after a cancel.
                        if let host = model.selectedHost,
                           LunaPower.shared.lastActionError[host.id] != nil {
                            Text("Couldn't wake this PC. Check that it's plugged in and Wake-on-LAN is enabled.")
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
                    Text("Cancel")
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
        // .connecting and .waking stay ENABLED - they're the cancel affordances.
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
            : role == .waking ? "Stop waiting for this PC to wake up"
            : "Right-click to choose an app")
        // VoiceOver hint mirrors the sighted-only `.help` so assistive-tech
        // users learn WHY the button is disabled (noPC) or what a click does.
        .accessibilityHint(
            role == .noPC ? "Pair a PC first to start streaming"
                : role == .connecting ? "Cancels the connection attempt"
                : role == .waking ? "Stops waiting for this PC to wake up"
                : role == .connect ? "Right-click to choose an app" : ""
        )
        .animation(.snappy(duration: 0.35, extraBounce: 0.1), value: isConnecting)
        .animation(.snappy(duration: 0.35, extraBounce: 0.1), value: model.isStreaming)
    }

    /// Steady primary line during connect. Prefers the SESSION's own friendly
    /// stage ("Connecting to <host>..." / "Cancelling…", stamped with the host
    /// captured at stream() entry): ⌘1-⌘9 can re-point `selectedHost`
    /// mid-handshake, and the capsule must keep naming the PC it's dialling.
    private var connectingPrimary: String {
        if case .connecting(let stage) = model.streamPhase,
           stage.hasPrefix("Connecting to ") || stage == "Cancelling…" {
            return stage
        }
        if let name = model.selectedHost?.displayName {
            return "Connecting to \(name)…"
        }
        return "Connecting…"
    }

    /// Optional engine-stage subtext below the primary line - surfaced only
    /// when the stage adds information beyond the primary ("RTSP handshake"),
    /// stripping whatever the primary already carries ("Connecting to X..."
    /// duplicates, the "Cancelling…" repaint).
    private var connectingSubtext: String? {
        guard case .connecting(let stage) = model.streamPhase, !stage.isEmpty else { return nil }
        if stage == connectingPrimary { return nil }
        if stage.hasPrefix("Connecting to ") || stage == "Connecting…" { return nil }
        return stage
    }
}
