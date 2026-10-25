// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AppKit
import SwiftUI

extension NSScreen {
    // cgDirectDisplayID arrived in macOS 26; NSScreenNumber carries the same ID on 15.
    var displayID: CGDirectDisplayID? {
        if #available(macOS 26, *) { return cgDirectDisplayID }
        return deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
    }
}

// macOS 15's stand-in for Observations, which callers use directly on 26. Each pass reads
// and re-arms tracking together, so no change can slip in between.
@MainActor
func forEachTrackedValue<Value>(_ read: () -> Value, perform body: (Value) -> Void) async {
    fatalError("clean-room: replace per spec-5")
}

// Liquid Glass on macOS 26. macOS 15 has no glass, so the same shapes get the system
// material instead: sizes and layout stay identical, only the surface changes.
extension View {
    @ViewBuilder
    func glassSurface<S: Shape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            glassEffect(.regular.tint(tint).interactive(interactive), in: shape)
        } else {
            background {
                shape.fill(.regularMaterial)
                if let tint { shape.fill(tint) }
            }
        }
    }

    @ViewBuilder
    func glassButtonStyle() -> some View {
        if #available(macOS 26, *) {
            buttonStyle(.glass)
        } else {
            buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    func glassWindowBackground() -> some View {
        if #available(macOS 26, *) {
            containerBackground(for: .window) { Color.clear.glassEffect(.regular, in: .rect) }
        } else {
            containerBackground(.regularMaterial, for: .window)
        }
    }
}

/// Composites adjacent glass as one cluster on macOS 26; a plain pass-through on macOS 15.
struct GlassGroup<Content: View>: View {
    let spacing: CGFloat
    @ViewBuilder let content: Content

    var body: some View {
        if #available(macOS 26, *) {
            GlassEffectContainer(spacing: spacing) { content }
        } else {
            content
        }
    }
}
