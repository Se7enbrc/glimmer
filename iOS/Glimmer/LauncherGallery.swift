// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Combine
import GameController
import GlimmerEngine
import SwiftUI

enum LauncherStyle: String, CaseIterable, Identifiable {
    case buttons, covers
    var id: Self { self }
    var label: String { self == .buttons ? "Buttons" : "Covers" }
}

enum LauncherGrid {
    static func columns(width: CGFloat, minimum: CGFloat, count: Int) -> Int {
        max(1, min(count, Int(max(0, width + 12) / max(1, minimum + 12))))
    }

    static func coverHeight(availableHeight: CGFloat) -> CGFloat {
        min(240, max(120, availableHeight - 160))
    }
}

struct AppGlyph: View {
    let name: String

    var body: some View {
        if name.localizedCaseInsensitiveContains("steam") {
            // The asset defines the medium scale; its font size still follows Dynamic Type.
            Image("steam").imageScale(.medium)
        } else {
            Image(systemName: name.lowercased() == "desktop" ? "macwindow" : "gamecontroller.fill")
        }
    }
}

@MainActor
struct LauncherGallery: View {
    let model: LauncherModel
    let style: LauncherStyle
    let size: CGSize
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @FocusState private var focusedAppID: Int?
    @State private var requestedMenuAppID: Int?
    @State private var menuController = LauncherMenuController()
    @Environment(\.scenePhase) private var scenePhase
    @ScaledMetric(relativeTo: .body) private var buttonMinimum: CGFloat = 220
    @ScaledMetric(relativeTo: .body) private var buttonHeight: CGFloat = 44
    @ScaledMetric(relativeTo: .body) private var coverMinimum: CGFloat = 128

    var body: some View {
        let coverHeight = LauncherGrid.coverHeight(availableHeight: size.height)
        let minimum: CGFloat = style == .buttons ? buttonMinimum : max(coverMinimum, coverHeight * 0.75)
        let count = LauncherGrid.columns(width: size.width, minimum: minimum,
                                         count: style == .buttons ? Int.max : model.apps.count)
        let width: CGFloat = style == .buttons ? size.width
            : min(size.width, CGFloat(count) * minimum + CGFloat(count - 1) * 12)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: count)
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(model.apps) { app in
                Group {
                    if style == .buttons {
                        LauncherButton(model: model, app: app, minimumHeight: buttonHeight)
                    } else {
                        LauncherCover(model: model, app: app,
                                      height: max(1, (width - CGFloat(count - 1) * 12) / CGFloat(count)) / 0.75)
                    }
                }
                .focused($focusedAppID, equals: app.id)
                .background {
                    LauncherControllerMenu(model: model, app: app, requestedAppID: $requestedMenuAppID)
                        .accessibilityHidden(true).allowsHitTesting(false)
                }
                .modifier(IOSControllerLayoutAppMenu(model: model, app: app))
                .modifier(RunningTilePresentation(model: model, app: app))
                .accessibilityIdentifier("launcher-app-\(app.id)")
            }
        }
        .frame(width: width, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
        .handlesGameControllerEvents(matching: .gamepad, withOptions: .receivesEventsInView(!model.hasActiveStream))
        .onAppear {
            menuController.openMenu = {
                if focusedAppID == model.runningApp?.id { requestedMenuAppID = focusedAppID }
            }
            menuController.update(active: scenePhase == .active, streaming: model.hasActiveStream)
        }
        .onDisappear { menuController.stop() }
        .onChange(of: model.hasActiveStream) { _, streaming in
            menuController.update(active: scenePhase == .active, streaming: streaming)
        }
        .onChange(of: scenePhase) { _, phase in
            menuController.update(active: phase == .active, streaming: model.hasActiveStream)
        }
        .onReceive(controllerChanges) { _ in
            menuController.update(active: scenePhase == .active, streaming: model.hasActiveStream)
        }
    }

    private var controllerChanges: AnyPublisher<Notification, Never> {
        guard scenePhase == .active, !model.hasActiveStream else { return Empty().eraseToAnyPublisher() }
        let center = NotificationCenter.default
        return Publishers.Merge(center.publisher(for: .GCControllerDidConnect),
                                center.publisher(for: .GCControllerDidDisconnect)).eraseToAnyPublisher()
    }
}

struct LauncherButton: View {
    let model: LauncherModel
    let app: HostApp
    let minimumHeight: CGFloat
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize

    @ScaledMetric(relativeTo: .caption2) private var badgeInset: CGFloat = 20

    var body: some View {
        Button { model.activateTile(app) } label: {
            HStack(spacing: 12) {
                if !dynamicTypeSize.isAccessibilitySize {
                    AppGlyph(name: app.name).font(.system(size: 20)).accessibilityHidden(true)
                }
                Text(app.name).fontWeight(.semibold)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
                if !dynamicTypeSize.isAccessibilitySize {
                    Image(systemName: "chevron.right").font(.caption).accessibilityHidden(true)
                }
            }
            .frame(maxWidth: .infinity, minHeight: minimumHeight, alignment: .leading)
            .padding(8)
            .padding(.top, dynamicTypeSize.isAccessibilitySize ? badgeInset : 0)
        }
        .buttonStyle(.glassProminent)
        .buttonBorderShape(.roundedRectangle(radius: RunningTileBadge.tileCornerRadius))
        .overlay(alignment: .topTrailing) {
            if model.runningApp?.id == app.id {
                RunningTileBadge(compact: true).fixedSize()
                    .padding(RunningTileBadge.cornerInset).allowsHitTesting(false)
            }
        }
        .disabled(model.busy)
    }
}

@MainActor
struct LauncherCover: View {
    let model: LauncherModel
    let app: HostApp
    let height: CGFloat
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var image: CGImage?

    var body: some View {
        Button { model.activateTile(app) } label: {
            VStack(alignment: .leading, spacing: 8) {
                Rectangle().fill(Color("AccentColor"))
                    .overlay {
                        if let image {
                            Image(decorative: image, scale: 1).resizable().scaledToFill()
                        } else {
                            AppGlyph(name: app.name).font(.largeTitle).foregroundStyle(.white)
                        }
                    }
                    .frame(height: height)
                    .clipped()
                    .clipShape(.rect(cornerRadius: RunningTileBadge.tileCornerRadius))
                    .overlay(alignment: .topTrailing) {
                        if model.runningApp?.id == app.id { RunningTileBadge().padding(RunningTileBadge.cornerInset) }
                    }
                Text(app.name).font(.headline).foregroundStyle(.primary)
                    .lineLimit(dynamicTypeSize.isAccessibilitySize ? nil : 2)
                    .fixedSize(horizontal: false, vertical: true)
                    .multilineTextAlignment(.leading)
                Text("Tap to resume").font(.footnote).foregroundStyle(.secondary)
                    .opacity(model.runningApp?.id == app.id ? 1 : 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(app.name)
        .accessibilityHint("Starts streaming from the PC.")
        .disabled(model.busy)
        .task(id: model.artworkRevision) {
            image = nil
            let loaded = await model.artwork(for: app)
            guard !Task.isCancelled else { return }
            image = loaded
        }
    }
}

struct RunningTilePresentation: ViewModifier {
    let model: LauncherModel
    let app: HostApp
    private var running: Bool { model.runningApp?.id == app.id }

    func body(content: Content) -> some View {
        content
            .overlay {
                if running {
                    RoundedRectangle(cornerRadius: RunningTileBadge.tileCornerRadius)
                        .strokeBorder(.primary.opacity(0.25), lineWidth: 1)
                        .padding(-3).allowsHitTesting(false)
                }
            }
            .accessibilityLabel(running ? "\(app.name), running. Resume stream" : app.name)
            .accessibilityHint(running ? "" : "Starts streaming from the PC.")
            .accessibilityActions {
                if running {
                    Button("Resume", action: model.continueGame)
                    Button("Quit \(app.name)…", action: model.requestQuit)
                }
            }
    }
}
