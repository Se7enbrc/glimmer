// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

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
            Image("steam")
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
    @ScaledMetric(relativeTo: .body) private var buttonMinimum = 220
    @ScaledMetric(relativeTo: .body) private var buttonHeight = 44
    @ScaledMetric(relativeTo: .body) private var coverMinimum = 128

    var body: some View {
        let coverHeight = LauncherGrid.coverHeight(availableHeight: size.height)
        let minimum = style == .buttons ? buttonMinimum : max(coverMinimum, coverHeight * 0.75)
        let count = LauncherGrid.columns(width: size.width, minimum: minimum, count: model.apps.count)
        let width = style == .buttons ? size.width
            : min(size.width, CGFloat(count) * minimum + CGFloat(count - 1) * 12)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 12, alignment: .top), count: count)
        LazyVGrid(columns: columns, spacing: 16) {
            ForEach(model.apps) { app in
                if style == .buttons {
                    Button { model.launch(app) } label: {
                        HStack(spacing: 12) {
                            AppGlyph(name: app.name).accessibilityHidden(true)
                            Text(app.name).fontWeight(.semibold).lineLimit(2)
                            Spacer(minLength: 0)
                            Image(systemName: "chevron.right").font(.caption).accessibilityHidden(true)
                        }
                        .frame(maxWidth: .infinity, minHeight: buttonHeight, alignment: .leading)
                        .padding(8)
                    }
                    .buttonStyle(.glassProminent)
                    .buttonBorderShape(.roundedRectangle)
                    .disabled(model.busy)
                } else {
                    LauncherCover(model: model, app: app,
                                  height: max(1, (width - CGFloat(count - 1) * 12) / CGFloat(count)) / 0.75)
                }
            }
        }
        .frame(width: width, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
struct LauncherCover: View {
    let model: LauncherModel
    let app: HostApp
    let height: CGFloat
    @State private var image: CGImage?

    var body: some View {
        Button { model.launch(app) } label: {
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
                    .clipShape(.rect(cornerRadius: 14))
                Text(app.name).font(.headline).foregroundStyle(.primary).lineLimit(2)
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
