// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AppKit
import Foundation

extension AppModel {
    func handleCommandURL(
        _ url: URL,
        dispatch: (([String: String]) -> Void)? = nil,
        resume: (() -> Void)? = nil
    ) {
        guard let command = GlimmerCLI.parseURL(url), let query = command.arguments.first,
              let host = GlimmerCLI.matchHost(query, in: hosts) else {
            Diag.notice("Ignored an unknown or malformed command URL", "Commands")
            return
        }
        var request = [CommandChannel.Key.id: UUID().uuidString,
                       CommandChannel.Key.verb: command.verb.rawValue, CommandChannel.Key.host: host.id]
        if command.verb == .stream {
            let name = command.arguments.dropFirst().first
            let app = name.flatMap { host.app(named: $0) } ?? (name == nil ? heroTargetApp(on: host) : nil)
            guard let app else {
                Diag.notice("Ignored a command URL for an unknown app", "Commands")
                return
            }
            if Self.isLiveStream(name == nil ? nil : app, on: host, live: isStreaming ? lastLaunchAttempt : nil) {
                if let resume { resume() } else { resumeStreamWindow() }
                return
            }
            request[CommandChannel.Key.app] = String(app.id)
        }
        if let dispatch { dispatch(request) } else { handleCommand(request, fromURL: true) }
    }

    /// The alert is mandatory for URL requests, even before the first PC poll answers.
    func confirmURLQuit(on host: Host, confirm: ((LibraryApp, Host) -> Void)? = nil) {
        let app = runningApp(on: host) ?? LibraryApp(id: 0, name: "the running app", hdr: false, hidden: false)
        if let confirm { confirm(app, host) } else { requestQuit(app, on: host) }
    }
}
