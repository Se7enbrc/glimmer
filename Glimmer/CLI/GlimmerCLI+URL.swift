// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

extension GlimmerCLI {
    /// URLs carry names, never command-line flags or permission to discard a game.
    nonisolated static func parseURL(_ url: URL) -> Command? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "glimmer", parts.user == nil, parts.password == nil,
              parts.port == nil, parts.path.isEmpty, parts.fragment == nil,
              let action = parts.host, let verb = Verb(rawValue: action),
              [.stream, .wake, .stop, .quit].contains(verb) else { return nil }
        var values: [String: String] = [:]
        for item in parts.queryItems ?? [] {
            guard item.name == "pc" || (verb == .stream && item.name == "app"),
                  values[item.name] == nil, let value = item.value,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { return nil }
            values[item.name] = value
        }
        guard let pc = values["pc"] else { return nil }
        return Command(verb: verb, arguments: [pc] + (values["app"].map { [$0] } ?? []))
    }
}
