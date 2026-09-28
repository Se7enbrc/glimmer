//
//  ContentViewSubviews.swift
//
//  Host-hero pieces split out of ContentView.swift: the app-icon and
//  spec-chip rows, plus the empty-pairing and stream-ended states.
//

import Accessibility
import AppKit
import SwiftUI

struct AppIconsRow: View {
    let apps: [LibraryApp]
    let host: Host
    @Environment(AppModel.self) private var model

    /// Two columns of wide, short tiles (the Home app's shape) fill the card's
    /// width with two apps or four; past four the last cell is the overflow menu.
    private static let maxInlineTiles = 4
    private static let columns = [GridItem(.flexible(), spacing: 8), GridItem(.flexible(), spacing: 8)]

    private var inlineApps: [LibraryApp] {
        apps.count <= Self.maxInlineTiles ? apps : Array(apps.prefix(Self.maxInlineTiles - 1))
    }

    private var overflowApps: [LibraryApp] {
        apps.count <= Self.maxInlineTiles ? [] : Array(apps.dropFirst(Self.maxInlineTiles - 1))
    }

    var body: some View {
        // One glass composite for the grid - see ReadinessChip's container note.
        GlassEffectContainer(spacing: 8) {
            LazyVGrid(columns: Self.columns, spacing: 8) {
                ForEach(inlineApps) { app in
                    appTile(app)
                }
                // Overflow is a MENU, not more rows: the window is sized to this
                // content, and a menu opens over it at no layout cost.
                if !overflowApps.isEmpty {
                    overflowMenu
                }
            }
        }
        // Dim the grid while a session exists; each tile is disabled on its own so
        // the overflow menu stays openable mid-session (looking launches nothing).
        .opacity(model.isStreaming ? 0.45 : 1.0)
        .animation(.snappy(duration: 0.3), value: model.isStreaming)
    }

    /// Icon, name, and a quiet play glyph: a click streams this app at once.
    private func tileLabel(systemImage: String, title: String, trailing: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 15, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .frame(width: 24, height: 24)
            Text(title)
                .font(.callout.weight(.medium))
                .lineLimit(1)
            Spacer(minLength: 0)
            Image(systemName: trailing)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .frame(maxWidth: .infinity, minHeight: 44)
        .contentShape(Rectangle())
    }

    private func appTile(_ app: LibraryApp) -> some View {
        Button {
            model.requestStream(app: app, on: host)
        } label: {
            tileLabel(systemImage: app.systemImage, title: app.name, trailing: "play.fill")
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 10))
        .disabled(model.isStreaming)
        .help(model.isStreaming ? "Finish the current stream first" : "Stream \(app.name)")
        // One name, not glyph + name + play glyph read in turn.
        .accessibilityLabel(app.name)
    }

    private var overflowMenu: some View {
        Menu {
            ForEach(overflowApps) { app in
                Button {
                    model.requestStream(app: app, on: host)
                } label: {
                    // macOS 27 hides a plain menu-item symbol image by default;
                    // these items name an app, so force the icon back on.
                    Label(app.name, systemImage: app.systemImage)
                        .labelStyle(.titleAndIcon)
                }
                .disabled(model.isStreaming)
            }
        } label: {
            tileLabel(systemImage: "ellipsis", title: "\(overflowApps.count) more", trailing: "chevron.down")
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .glassEffect(.regular.interactive(), in: .rect(cornerRadius: 10))
        .help(model.isStreaming
            ? "Finish the current stream first"
            : "Show \(overflowApps.count) more app\(overflowApps.count == 1 ? "" : "s")")
        .accessibilityLabel("\(overflowApps.count) more apps")
        .accessibilityHint("Shows the rest of this PC's apps")
    }
}

struct SpecChipsRow: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Facts, not controls: one secondary line, so nothing here looks pressable.
        Text(model.streamSpecChips.joined(separator: " · "))
            .font(.callout)
            .foregroundStyle(.secondary)
    }
}

// MARK: - Empty pairing state

struct EmptyPairingState: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    /// Owned by MainWindow so its `.sheet` survives the swap to ConnectSurface
    /// the moment pairing fills `model.hosts` - see MainWindow.showPair.
    @Binding var showPair: Bool

    var body: some View {
        // No leading/trailing Spacers: they centred this state inside a window
        // taller than itself, and the window now sizes to its content, so there
        // is no extra height to centre within - only height they would invent.
        VStack(spacing: 26) {
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
                Text("Glimmer plays your PC's games on this Mac.")
                    .font(.title3)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 440)
            }

            Button {
                showPair = true
            } label: {
                Label("Pair a PC…", systemImage: "plus.circle.fill")
                    .frame(minWidth: 260)
            }
            .buttonStyle(StreamButtonStyle())
            .controlSize(.large)
        }
        .padding(40)
        .fixedSize(horizontal: false, vertical: true)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
                .transition(reduceMotion ? .opacity : .move(edge: .top).combined(with: .opacity))
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
        .animation(.snappy(duration: 0.30, extraBounce: reduceMotion ? 0 : 0.1),
                   value: model.streamEndedToastVisible)
    }
}
