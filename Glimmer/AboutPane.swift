//
//  AboutPane.swift
//
//  Settings → About. App identity, the credo, version (with the option-click
//  Diagnostics reveal), credits, license, and the donate link. Split out of
//  SettingsPCsShortcutsPanes.swift to keep that file under the 600-line bar.
//

import AppKit
import SwiftUI

/// Single source of truth for the About pane's outbound links. Strings (not
/// force-unwrapped URLs) so the pane renders link rows with a lint-clean
/// `if let`; a malformed constant degrades to "row missing", never a crash.
private enum AboutLink {
    static let credits = "https://github.com/Se7enbrc/glimmer/blob/main/CREDITS.md"
    static let license = "https://www.gnu.org/licenses/gpl-3.0.html"
    static let sunshine = "https://github.com/LizardByte/Sunshine"
    static let moonlight = "https://github.com/moonlight-stream"
    /// The support link - the donate row reads this one constant and nothing
    /// else. Mirrors the repo's FUNDING.yml (Ko-fi).
    static let donate = "https://ko-fi.com/ugfuglio"
}

struct AboutPane: View {
    @Environment(MoonlightManager.self) private var moonlight

    var body: some View {
        // First-party utility tone - see System Settings ▸ About, Disk
        // Utility ▸ About, Activity Monitor ▸ About: app name + plain
        // description + version + credits. No marketing voice, no
        // exclamation marks, no comparisons to other products. The credo
        // is the one allowed line of soul.
        Form {
            Section {
                HStack(spacing: 18) {
                    if let icon = NSImage(named: "AppIcon") {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 96, height: 96)
                            .clipShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
                            .shadow(color: .black.opacity(0.20), radius: 10, x: 0, y: 4)
                    } else {
                        Image(systemName: "moon.stars.fill")
                            .font(.system(size: 64))
                            .foregroundStyle(.tint)
                            .frame(width: 96, height: 96)
                    }
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Glimmer")
                            .font(.system(size: 28, weight: .bold))
                            .tracking(-0.4)
                        Text("Stream your gaming PC to this Mac.")
                            .font(.title3)
                            .foregroundStyle(.secondary)
                        // The credo. One line, no elaboration - it is the
                        // project's bar, not a slogan to be decorated.
                        Text("Highest fidelity. Lowest resources. Rock stable.")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .italic()
                        Text("Version \(versionString)")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            // Hidden reveal for the telemetry/tuning sections
                            // inside Settings → Diagnostics (the pane itself is
                            // always visible for the input test + logs; only the
                            // debug wires hide). Option-clicking the version line
                            // toggles the `showDiagnostics` UserDefault - a
                            // deliberate, undiscoverable gesture so normal users
                            // never trip it, but a power user (or a bug report)
                            // can surface them. The Telemetry toggle lives inside
                            // those sections, so it can't gate its own reveal -
                            // hence this separate gesture-driven flag.
                            .gesture(
                                TapGesture()
                                    .modifiers(.option)
                                    .onEnded { moonlight.showDiagnostics.toggle() }
                            )
                            // Option-cursor hint that something lives here,
                            // without spelling it out.
                            .help(moonlight.showDiagnostics
                                  ? "Option-click to hide the developer tools"
                                  : "")
                    }
                    Spacer()
                }
                .padding(.vertical, 6)
            }
            // Order: Support up top (the one ask), License in the middle (the
            // legal fact), and the projects we lean on at the bottom as a
            // closing note of appreciation.
            Section("Support") {
                if let url = URL(string: AboutLink.donate) {
                    Link("Support Glimmer's development", destination: url)
                        .font(.footnote)
                }
            }
            Section("License") {
                Text("Glimmer is free software under the GNU General Public License v3. "
                    + "You may run, study, share, and modify it; there is no warranty.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let url = URL(string: AboutLink.license) {
                    Link("GNU GPL v3", destination: url)
                        .font(.footnote)
                }
            }
            Section("Projects we like") {
                Text("Built for Sunshine, the open-source game-streaming host. Glimmer "
                    + "speaks the Moonlight protocol - itself carrying NVIDIA GameStream "
                    + "forward - and the transport is ported from moonlight-common-c, "
                    + "with respect. Full credits in CREDITS.md.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let url = URL(string: AboutLink.sunshine) {
                    Link("github.com/LizardByte/Sunshine", destination: url)
                        .font(.footnote)
                }
                if let url = URL(string: AboutLink.moonlight) {
                    Link("github.com/moonlight-stream", destination: url)
                        .font(.footnote)
                }
                if let url = URL(string: AboutLink.credits) {
                    Link("Credits", destination: url)
                        .font(.footnote)
                }
            }
        }
        .formStyle(.grouped)
    }

    /// "1.2.3 (45)" - short marketing version + build number, matching
    /// what System Settings ▸ General ▸ About shows for first-party apps.
    private var versionString: String {
        let short = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "-"
        if let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String, !build.isEmpty, build != short {
            return "\(short) (\(build))"
        }
        return short
    }
}
