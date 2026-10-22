// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

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

import GlimmerEngine
import SwiftUI

enum ChipPresentation: Equatable {
    case checkingReadiness(reason: String)
    case noPC                                   // gray dot, "No PC"
    case ready(rttMs: Int?)                     // green dot, "Ready" / "Ready · 12 ms"
    case streamingOurs                          // green, "Streaming" (our session)
    case connecting(phase: String)              // amber dot, current handshake phase
    case asleep                                 // dim gray dot, "Asleep"
    case certMismatch                           // amber dot, "Trust needed"
    case unknown                                // amber dot, "Checking..." (pre-first-poll)

    /// Truncated, single-line label - the chip must stay narrower than the
    /// hero, and game names can be long; we cap at 22 chars.
    var label: String {
        switch self {
        case .connecting(let phase): Self.truncate(phase, to: 22)
        default: fullLabel
        }
    }

    /// The same words untruncated, where there's room (`glimmer list`).
    var fullLabel: String {
        switch self {
        case .checkingReadiness(let reason): reason
        case .noPC: "No PC"
        case .ready(nil): "Ready"
        case .ready(let ms?): "Ready · \(ms) ms"
        case .streamingOurs: "Streaming"
        // Friendly strings ("Connecting to Tower...") - pass through.
        case .connecting(let phase): phase
        case .asleep: "Asleep"
        case .certMismatch: "Trust needed"
        case .unknown: "Checking…"
        }
    }

    /// The screen-reader sentence, so the chip isn't read as bare jargon.
    var accessibility: String {
        switch self {
        case .checkingReadiness(let reason): return reason
        case .noPC: return "No PC selected"
        case .ready(nil): return "PC ready"
        case .ready(let ms?): return "PC ready, round trip \(ms) milliseconds"
        case .streamingOurs: return "Streaming"
        case .connecting(let phase): return phase
        case .asleep: return "PC is asleep or unreachable"
        // Matches the visible label so Voice Control's "Click Trust needed"
        // finds the button; the hint carries the re-pair action.
        case .certMismatch: return "Trust needed"
        case .unknown: return "Checking PC status"
        }
    }

    var dotColor: Color {
        switch self {
        case .checkingReadiness: return Color.orange
        case .noPC: return Color.gray
        case .ready: return Color.green
        case .streamingOurs: return Color.green
        case .connecting: return Color.orange
        case .asleep: return Color.secondary
        case .certMismatch: return Color.orange
        case .unknown: return Color.orange
        }
    }

    /// A PC's polled state. No sample yet, or one past the stale window (the
    /// PC stopped answering a while back), reads as Checking.
    init(live: HostLiveStatus?, now: Date = Date()) {
        guard let live, now.timeIntervalSince(live.capturedAt) <= HostLiveStatus.stale else {
            self = .unknown
            return
        }
        switch live.state {
        case .unknown: self = .unknown
        case .idle, .streamingApp, .streamingUnknownApp: self = .ready(rttMs: live.rttMs)
        case .asleep: self = .asleep
        case .certMismatch: self = .certMismatch
        }
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

    var body: some View {
        let chip = model.selectedReadinessChip
        // GlassEffectContainer composites adjacent glass elements as ONE
        // floating cluster (Apple's Liquid Glass guidance) instead of
        // stacking independent blur passes into double-blur artefacts.
        GlassGroup(spacing: 8) {
            HStack(spacing: 8) {
                Group {
                    // certMismatch is the Trust affordance: a REAL Button, so
                    // Tab and VoiceOver can reach it (an .onTapGesture alone
                    // is invisible to both). Re-pairing re-pins the new cert.
                    if chip == .certMismatch {
                        Button { model.requestPairing(for: model.selectedHost) } label: { pill(for: chip) }
                            .buttonStyle(.plain)
                    } else {
                        pill(for: chip)
                    }
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(accessibilitySummary(for: chip))
                .accessibilityAddTraits(chip == .certMismatch ? .isButton : [])
                .accessibilityHint(chip == .certMismatch ? "Pairs again to trust this PC's new certificate." : "")
            }
        }
        .animation(Motion.layout(reduceMotion: reduceMotion), value: model.selectedReadinessChip)
        .animation(Motion.layout(reduceMotion: reduceMotion), value: model.hostRoute.routeClass)
    }

    /// The dot + label + route-glyph capsule, shared by the plain chip and
    /// the certMismatch Button so both render identically.
    private func pill(for chip: ChipPresentation) -> some View {
        HStack(spacing: 6) {
            Circle()
                .fill(chip.dotColor)
                .frame(width: 7, height: 7)
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
        .glassSurface(in: .capsule)
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

extension AppModel {
    var selectedReadinessChip: ChipPresentation {
        guard let host = selectedHost else { return .noPC }
        if let reason = selectedReadinessReason { return .checkingReadiness(reason: reason) }
        if streamingHostID == host.id {
            if case .connecting(let stage) = streamPhase { return .connecting(phase: stage) }
            return .streamingOurs
        }
        return polledChip(for: host)
    }
}
