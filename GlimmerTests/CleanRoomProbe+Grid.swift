// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AppKit
import Foundation
import SwiftUI
#if canImport(GlimmerEngine)
@testable import GlimmerEngine
#endif
@testable import Glimmer

extension CleanRoomProbe {
    struct GridInput: Codable, Sendable {
        let apps: [String]
    }

    // The inline partition and the overflow control as accessibility presents it. SwiftUI builds the
    // menu's items only while it is open, which a test cannot do without a modal tracking loop.
    struct GridOutput: Codable, Equatable, Sendable {
        let inline: [String]
        let control: [String]
    }

    static let grid = area("grid") { (input: GridInput) -> GridOutput in observeGrid(input) }

    @MainActor
    static func observeGrid(_ input: GridInput) -> GridOutput {
        let apps = input.apps.enumerated().map { LibraryApp(id: 500 + $0.offset, name: $0.element, hdr: false, hidden: false) }
        let inline = AppIconsRow.inlineApps(apps).map(\.name)
        guard let rendered = CleanRoomGridHost.render(apps: apps) else {
            return GridOutput(inline: inline, control: ["unrendered"])
        }
        defer { rendered.close() }
        var control: [String] = []
        var pending: [Any] = [rendered.view]
        var seen: Set<ObjectIdentifier> = []
        while let next = pending.popLast() {
            guard seen.insert(ObjectIdentifier(next as AnyObject)).inserted else { continue }
            if let view = next as? NSView { pending += view.subviews }
            guard let element = next as? NSAccessibilityProtocol else { continue }
            pending += element.accessibilityChildren() ?? []
            guard let label = element.accessibilityLabel(), label.contains("more") else { continue }
            control.append("\(element.accessibilityRole()?.rawValue ?? "?") \(label) | \(element.accessibilityHelp() ?? "")")
        }
        return GridOutput(inline: inline, control: control.sorted())
    }
}
