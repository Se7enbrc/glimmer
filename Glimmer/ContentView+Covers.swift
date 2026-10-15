// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import SwiftUI

extension AppIconsRow {
    var coverGrid: some View {
        let revision = LauncherArtCache.revision(apps: host.apps)
        let columns = LauncherLayout.columns(appCount: apps.count)
        let rows = (apps.count + columns - 1) / columns
        let rowHeight = LauncherLayout.coverHeight(appCount: apps.count) + 48
        return ScrollViewReader { reader in
            ScrollView(.vertical) {
                LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 10), count: columns),
                          spacing: 10) {
                    ForEach(apps) { app in
                        appTile(app, revision: revision).id(LauncherFocus.app(app.id))
                    }
                }
                .padding(.vertical, 16)
                .padding(.horizontal, LauncherLayout.coverPadding)
            }
            .scrollDisabled(rows <= 2)
            .frame(height: CGFloat(min(rows, 2)) * rowHeight + CGFloat(min(rows, 2) - 1) * 10 + 32)
            .onChange(of: focus.wrappedValue) { _, value in
                if let value { reader.scrollTo(value) }
            }
        }
    }

    func coverLabel(_ app: LibraryApp, revision: String, connecting: Bool, hiddenStream: Bool) -> some View {
        VStack(spacing: 6) {
            LauncherCoverArt(app: app, host: host, revision: revision,
                             height: LauncherLayout.coverHeight(appCount: apps.count))
            VStack(spacing: 2) {
                Text(app.name).font(.headline).lineLimit(1)
                if connecting {
                    ProgressView().controlSize(.mini)
                } else if hiddenStream {
                    Text("Back to Stream").font(.caption)
                } else if isRunning(app) {
                    Label("Running", systemImage: "play.fill").font(.caption).foregroundStyle(.secondary)
                }
            }
            .frame(height: 42, alignment: .top)
        }
    }

    func isRunning(_ app: LibraryApp) -> Bool {
        model.launcherAppIsRunning(app, on: host)
    }
}

struct LauncherCoverArt: View {
    let app: LibraryApp
    let host: Host
    let revision: String
    let height: CGFloat
    @Environment(AppModel.self) private var model
    @State private var image: CGImage?

    @State private var shownKey: String?
    private var key: String { "\(host.id):\(app.id):\(revision)" }
    private var reachable: Bool { model.launcherArtReachable(for: host.id) }

    var body: some View {
        ZStack {
            if let image {
                Image(decorative: image, scale: 1).resizable().scaledToFill()
            } else {
                RoundedRectangle(cornerRadius: 14, style: .continuous).accentSurface()
                app.icon.font(.system(size: 36, weight: .semibold)).foregroundStyle(.white)
            }
        }
        .frame(width: height * 3 / 4, height: height)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .contentShape(.focusEffect, RoundedRectangle(cornerRadius: 14, style: .continuous))
        .shadow(color: .black.opacity(0.18), radius: 12, x: 0, y: 4)
        .task(id: "\(key)-\(model.isStreaming)-\(reachable)") {
            if shownKey != key { image = nil; shownKey = key }
            guard !model.isStreaming, image == nil else { return }
            let data = await model.launcherArt(for: app, on: host, revision: revision)
            guard !Task.isCancelled, let data else { return }
            image = LauncherArtCache.decode(data)
        }
    }
}

extension AppModel {
    func launcherAppIsRunning(_ app: LibraryApp, on host: Host) -> Bool {
        if isStreaming {
            return streamPhase == .streaming && lastLaunchAttempt?.host.id == host.id
                && lastLaunchAttempt?.app.id == app.id
        }
        guard let status = hostLiveStatus,
              HostLiveStatus.isFresh(status, for: host.id) else { return false }
        if case .streamingApp(let name) = status.state { return name == app.name }
        if case .streamingUnknownApp(let id) = status.state { return id == app.id }
        return false
    }

    func launcherArtReachable(for pcID: String) -> Bool {
        guard let status = hostLiveStatus, status.hostID == pcID else { return false }
        switch status.state {
        case .idle, .streamingApp, .streamingUnknownApp: return true
        case .unknown, .asleep, .certMismatch: return false
        }
    }

    func launcherArt(for app: LibraryApp, on host: Host, revision: String) async -> Data? {
        guard !isStreaming else { return nil }
        let makeNetwork = makeNetwork
        let server = nativeServerInfo(for: host)
        return await launcherArtCache.image(pcID: host.id, appID: app.id, revision: revision) {
            let client = makeNetwork(server)
            do {
                let data = try await client.appAsset(appID: app.id)
                await client.shutdown()
                return data
            } catch {
                await client.shutdown()
                throw error
            }
        }
    }
}

struct LauncherTileStyle: ButtonStyle {
    let covers: Bool
    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @ViewBuilder func makeBody(configuration: Configuration) -> some View {
        if covers {
            configuration.label
                .opacity(isEnabled ? 1 : 0.55)
                .scaleEffect(Motion.pressedScale(configuration.isPressed, reduceMotion: reduceMotion))
                .animation(Motion.press(reduceMotion: reduceMotion), value: configuration.isPressed)
        } else {
            AppTileStyle().makeBody(configuration: configuration)
        }
    }
}
