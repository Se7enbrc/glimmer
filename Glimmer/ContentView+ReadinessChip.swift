//
//  ContentView+ReadinessChip.swift
//
//  The hero's top-leading readiness chip and the composite status model behind
//  it (`ChipPresentation`): one capsule that folds our own session, the polled
//  host state, the route glyph, and the HDR badge into a single line, and that
//  doubles as the re-pair affordance when a host's certificate changed. Split
//  out of ContentViewSubviews.swift to keep each file under the length limit;
//  see that file for the remaining hero pieces.
//

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
        case .unknown: return "Checking…"
        }
    }

    /// The screen-reader sentence, so the chip isn't read as bare jargon.
    var accessibility: String {
        switch self {
        case .noPC: return "No PC selected"
        case .ready(nil): return "PC ready"
        case .ready(let ms?): return "PC ready, round trip \(ms) milliseconds"
        case .streamingOurs: return "Streaming"
        case .connecting(let phase): return phase
        case .streamingElsewhere(let name): return "PC is streaming \(name)"
        case .asleep: return "PC is asleep or unreachable"
        case .certMismatch: return "PC certificate changed, re-pair to trust it"
        case .unknown: return "Checking PC status"
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
        return str[str.startIndex..<end] + "…"
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
