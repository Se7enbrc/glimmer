// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import SwiftUI

struct RunningTileBadge: View {
    static let tileCornerRadius: CGFloat = 14
    static let cornerInset = tileCornerRadius / 2

    var compact = false

    var body: some View {
        HStack(spacing: 4) {
            Circle().fill(.green).frame(width: 6, height: 6)
            Text("Running").font(.caption2.weight(.semibold))
        }
        .foregroundStyle(Color.primary)
        .padding(.horizontal, 7)
        .padding(.vertical, compact ? 2 : 4)
        .background(.regularMaterial, in: Capsule())
        .accessibilityHidden(true)
    }
}
