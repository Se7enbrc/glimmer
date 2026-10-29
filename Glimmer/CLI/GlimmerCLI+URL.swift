// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import GlimmerEngine

extension GlimmerCLI {
    /// URLs carry names, never command-line flags. Quit keeps its separate confirmation.
    nonisolated static func parseURL(_ url: URL) -> Command? {
        guard let parsed = GlimmerCommandURL.parse(url), let verb = Verb(rawValue: parsed.action.rawValue) else {
            return nil
        }
        return Command(verb: verb, arguments: [parsed.pc, parsed.app].compactMap { $0 })
    }
}
