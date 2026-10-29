// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

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
    static let support = "https://se7enbrc.github.io/glimmer/support/"
    static let privacy = "https://se7enbrc.github.io/glimmer/privacy/"
    /// The support link - the donate row reads this one constant and nothing
    /// else. Mirrors the repo's FUNDING.yml (GitHub Sponsors).
    static let donate = "https://github.com/sponsors/Se7enbrc"
}

struct AboutPane: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        // Keep identity and links in the same quiet style as system About panes.
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
                        if DiagnosticBuild.isEnabled {
                            Text("Diagnostic build · performance recording enabled by default")
                                .font(.footnote)
                                .foregroundStyle(.secondary)
                        }
                        Text("Version \(versionString)")
                            .font(.footnote)
                            .foregroundStyle(.tertiary)
                            // The diagnostics toggle lives inside the hidden sections,
                            // so Option-click provides an independent reveal.
                            .gesture(
                                TapGesture()
                                    .modifiers(.option)
                                    .onEnded { model.showDiagnostics.toggle() }
                            )
                            // Option-cursor hint that something lives here,
                            // without spelling it out.
                            .help(model.showDiagnostics
                                  ? "Option-click to hide the developer tools"
                                  : "")
                    }
                    Spacer()
                }
                .padding(.vertical, 6)
            }
            Section("Support") {
                if let url = URL(string: AboutLink.support) {
                    Link("Support", destination: url)
                        .font(.footnote)
                }
                if let url = URL(string: AboutLink.privacy) {
                    Link("Privacy Policy", destination: url)
                        .font(.footnote)
                }
                if let url = URL(string: AboutLink.donate) {
                    Link("Support Glimmer's development", destination: url)
                        .font(.footnote)
                }
            }
            Section("License") {
                Text("Glimmer is free software under the GNU General Public License v3. "
                    + "You may run, study, share, and modify it. There is no warranty.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                if let url = URL(string: AboutLink.license) {
                    Link("GNU GPL v3", destination: url)
                        .font(.footnote)
                }
            }
            Section("Acknowledgements") {
                Text("Built for Sunshine, the open-source game-streaming app that runs on "
                    + "your PC. Glimmer talks to it over the same RTSP-based protocol as Moonlight, "
                    + "the client that inspired it, and the transport is ported from "
                    + "moonlight-common-c, with respect.")
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
