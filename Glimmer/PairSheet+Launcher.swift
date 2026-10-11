// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import SwiftUI

struct PairLauncherChoice: View {
    let host: Host
    @Environment(AppModel.self) private var model

    private var selection: LauncherStyle {
        model.hosts.first(where: { $0.id == host.id })?.launcherStyle ?? .buttons
    }

    var body: some View {
        let revision = LauncherArtCache.revision(apps: host.apps)
        VStack(alignment: .leading, spacing: 16) {
            Text("How should \(host.displayName)'s apps appear?")
                .font(.headline)
            HStack(alignment: .top, spacing: 12) {
                ForEach(LauncherStyle.allCases, id: \.self) { style in
                    Button { model.setLauncherStyle(style, for: host) } label: {
                        VStack(spacing: 12) {
                            preview(style, revision: revision)
                                .frame(width: 174, height: 144)
                                .accessibilityHidden(true)
                            Label(style.title, systemImage: selection == style ? "checkmark.circle.fill" : "circle")
                                .font(.headline)
                        }
                        .padding(8)
                    }
                    .buttonStyle(.bordered)
                    .tint(selection == style ? Color.accentColor : nil)
                    .accessibilityLabel(style.title)
                    .accessibilityAddTraits(selection == style ? .isSelected : [])
                }
            }
        }
    }

    @ViewBuilder private func preview(_ style: LauncherStyle, revision: String) -> some View {
        let apps = Array(LauncherStyle.customApps(in: host.apps).prefix(2))
        if style == .covers {
            HStack(alignment: .top, spacing: 10) {
                ForEach(apps) { app in
                    VStack(spacing: 6) {
                        LauncherCoverArt(app: app, host: host, revision: revision, height: 104)
                        Text(app.name).font(.caption).lineLimit(1).frame(width: 78)
                    }
                }
            }
        } else {
            VStack(spacing: 10) {
                ForEach(apps) { app in
                    HStack(spacing: 8) {
                        app.icon
                        Text(app.name).font(.headline).lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "play.fill").font(.caption)
                    }
                    .foregroundStyle(.white)
                    .padding(10)
                    .background { RoundedRectangle(cornerRadius: 14, style: .continuous).accentSurface() }
                }
            }
        }
    }
}
