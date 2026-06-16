import AppKit
import os
import ServiceManagement
import SwiftUI

// MARK: - Settings Root

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, streaming, pcs, shortcuts, troubleshooting, diagnostics, about

    var id: String { rawValue }
    var title: String {
        switch self {
        case .general: return "General"
        // Titled "Quality" — the pane is about how the stream looks and
        // feels, not the act of streaming. The case name (and rawValue
        // "streaming") stays put: selection is session-only @State today,
        // but keeping the raw value stable means nothing breaks if it is
        // ever persisted or deep-linked.
        case .streaming: return "Quality"
        case .pcs: return "PCs"
        // Titled "Input" — it now holds every input control (shortcuts, macOS
        // keys, controller raw-HID + quit chord, mouse). Case/rawValue
        // "shortcuts" stays put so nothing persisted/deep-linked breaks.
        case .shortcuts: return "Input"
        case .troubleshooting: return "Troubleshooting"
        case .diagnostics: return "Diagnostics"
        case .about: return "About"
        }
    }
    var systemImage: String {
        switch self {
        case .general: return "gearshape.fill"
        // A quality dial, not a play button — the pane tunes how the
        // stream looks, it doesn't start one. `dial.high.fill` has shipped
        // since SF Symbols 3, so no missing-glyph risk on macOS 26.
        case .streaming: return "dial.high.fill"
        case .pcs: return "display"
        case .shortcuts: return "keyboard.fill"
        case .troubleshooting: return "stethoscope"
        case .diagnostics: return "waveform.path.ecg"
        // System Settings' About uses `info.circle.fill` — the bare "info"
        // symbol doesn't ship in SF Symbols 6 and falls back to a missing
        // glyph on macOS 26.
        case .about: return "info.circle.fill"
        }
    }
    // System Settings-style colored chip behind each sidebar SF Symbol.
    var chipColor: Color {
        switch self {
        case .general: return .gray
        case .streaming: return .red
        case .pcs: return .orange
        case .shortcuts: return .indigo
        case .troubleshooting: return .teal
        case .diagnostics: return .purple
        case .about: return .gray
        }
    }
}

struct SettingsRoot: View {
    @Environment(MoonlightManager.self) private var moonlight
    @State private var selection: SettingsPane = .general

    /// Panes shown in the sidebar. Diagnostics is HIDDEN until revealed by the
    /// option-click gesture on the version line in About — normal users never
    /// see it, so the debug/tuning wires stay out of the way.
    private var visiblePanes: [SettingsPane] {
        SettingsPane.allCases.filter { $0 != .diagnostics || moonlight.showDiagnostics }
    }

    var body: some View {
        // NavigationSplitView's master column auto-adopts Liquid Glass
        // sidebar material on macOS 26 (same chrome System Settings uses).
        // We pair it with `.scrollContentBackground(.hidden)` on the List
        // so the sidebar's own opaque list background doesn't paint over
        // the translucent window material the Settings scene provides.
        NavigationSplitView(columnVisibility: .constant(.all)) {
            List(visiblePanes, selection: $selection) { pane in
                HStack(spacing: 8) {
                    Image(systemName: pane.systemImage)
                        .font(.system(size: 11, weight: .bold))
                        .symbolRenderingMode(.monochrome)
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(
                            // Subtle top-edge highlight on the colored chip
                            // — matches Tahoe's System Settings chips for
                            // Bluetooth/Network/etc. The gradient lightens
                            // the top ~40% of the chip and falls off to the
                            // base color, giving the glossy "lit from above"
                            // feel without an additional stroke.
                            RoundedRectangle(cornerRadius: 6, style: .continuous)
                                .fill(pane.chipColor)
                                .overlay(
                                    LinearGradient(
                                        colors: [
                                            Color.white.opacity(0.30),
                                            Color.white.opacity(0.0)
                                        ],
                                        startPoint: .top,
                                        endPoint: .center
                                    )
                                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                                    .blendMode(.plusLighter)
                                    .allowsHitTesting(false)
                                )
                        )
                    Text(pane.title)
                }
                .tag(pane)
            }
            .scrollContentBackground(.hidden)
            .navigationSplitViewColumnWidth(min: 170, ideal: 190)
            .toolbar(removing: .sidebarToggle)
            // If the user collapses the Diagnostics reveal while it's the
            // selected pane, fall back to General so the detail view doesn't
            // point at a now-hidden pane.
            .onChange(of: moonlight.showDiagnostics) { _, shown in
                if !shown, selection == .diagnostics { selection = .general }
            }
        } detail: {
            Group {
                switch selection {
                case .general: GeneralPane()
                case .streaming: QualityPane()
                case .pcs: PCsPane()
                case .shortcuts: ShortcutsPane()
                case .troubleshooting: TroubleshootingPane()
                case .diagnostics: DiagnosticsPane()
                case .about: AboutPane()
                }
            }
            // Hide the detail pane's scroll/form opaque background so the
            // Settings window's `.thinMaterial` chrome shows through. On
            // macOS 26 grouped Forms auto-upgrade their Section backgrounds
            // to the Tahoe inset-rounded glass material once nothing is
            // painting over the container.
            .scrollContentBackground(.hidden)
            .navigationTitle(selection.title)
        }
        .navigationSplitViewStyle(.balanced)
    }
}
