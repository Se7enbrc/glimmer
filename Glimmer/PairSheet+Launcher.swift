// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI

struct PairLauncherChoice: View {
    let host: Host
    let focus: FocusState<LauncherFocus?>.Binding
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
                    .pairingFocus(focus, .style(style)) { model.setLauncherStyle(style, for: host) }
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

enum PairingFocus: Hashable {
    case pc(String), manual, address, continuePairing, help, back, cancel, retry, done, stream
    case style(LauncherStyle), settings, guide
}

enum PairingNavigation {
    static func destination(from focus: LauncherFocus?, command: LauncherCommand,
                            cells: [LauncherFocus]) -> LauncherFocus? {
        let direction: LauncherCommand
        switch command {
        case .left: direction = .up
        case .right: direction = .down
        default: direction = command
        }
        return LauncherNavigation.destination(from: focus, command: direction,
                                              cells: cells, columns: 1, hasSwitcher: false)
    }
}

private struct PairingControlFocus: ViewModifier {
    let focus: FocusState<LauncherFocus?>.Binding
    let target: PairingFocus
    let activate: () -> Void
    @Environment(\.isEnabled) private var isEnabled

    func body(content: Content) -> some View {
        content
            .modifier(LauncherControlFocus(focus: focus, target: .pairing(target), activate: activate))
            .preference(key: LauncherFocusCells.self, value: isEnabled ? [.pairing(target)] : [])
    }
}

extension View {
    func pairingFocus(_ focus: FocusState<LauncherFocus?>.Binding, _ target: PairingFocus,
                      activate: @escaping () -> Void) -> some View {
        modifier(PairingControlFocus(focus: focus, target: target, activate: activate))
    }
}
