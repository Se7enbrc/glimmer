// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import GlimmerEngine
import AppKit
import Foundation

extension AppModel {
    func handleCommandURL(
        _ url: URL,
        dispatch: (([String: String]) -> Void)? = nil,
        resume: (() -> Void)? = nil,
        confirm: ((CommandURLPrompt) -> Bool)? = nil
    ) {
        guard let command = GlimmerCLI.parseURL(url) else {
            Diag.notice("Ignored an unknown or malformed command URL", "Commands")
            return
        }
        if command.verb == .stop {
            var request = [CommandChannel.Key.id: UUID().uuidString, CommandChannel.Key.verb: "stop"]
            request[CommandChannel.Key.pc] = command.arguments.first
            if let dispatch { dispatch(request) } else { handleCommand(request, fromURL: true, confirmExternal: confirm) }
            return
        }
        guard let query = command.arguments.first,
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
        if let dispatch { dispatch(request) } else { handleCommand(request, fromURL: true, confirmExternal: confirm) }
    }

    struct URLCommandScope: Equatable {
        let session: UUID?
        let pending: String?
        let streaming: Bool
        let pc: String?
        let app: Int?
    }

    var urlCommandScope: URLCommandScope {
        URLCommandScope(session: nativeSession?.id, pending: pendingCommandStream?.id, streaming: isStreaming,
                        pc: lastLaunchAttempt?.host.id, app: lastLaunchAttempt?.app.id)
    }

    func confirmURLAction(_ prompt: CommandURLPrompt, confirm: ((CommandURLPrompt) -> Bool)?) -> Bool {
        guard CommandURLPrompt.requiresConfirmation(prompt.action) else { return true }
        let scope = urlCommandScope
        let approved: Bool
        if let confirm { approved = confirm(prompt) } else {
            let alert = NSAlert()
            alert.messageText = prompt.title
            alert.informativeText = prompt.message
            alert.addButton(withTitle: "Cancel")
            alert.addButton(withTitle: prompt.button).hasDestructiveAction = prompt.action != .stream
            NSApp.activate()
            approved = alert.runModal() == .alertSecondButtonReturn
        }
        return approved && scope == urlCommandScope
    }

    func confirmURLStop(matching query: String?, confirm: ((CommandURLPrompt) -> Bool)?) -> Bool {
        guard nativeSession != nil || nativeStreamTask != nil || pendingCommandStream != nil,
              let host = pendingCommandStream?.host ?? lastLaunchAttempt?.host else { return true }
        if let query, GlimmerCLI.matchHost(query, in: [host]) == nil { return true }
        return confirmURLAction(CommandURLPrompt(action: .stop, pc: host.displayName,
                                                app: lastLaunchAttempt?.app.name ?? "the app"), confirm: confirm)
    }

    /// Web links must ask before discarding the PC's game.
    func confirmURLQuit(on host: Host, confirm: ((LibraryApp, Host) -> Void)? = nil) {
        let name = hostLiveStatus.flatMap { live -> String? in
            guard HostLiveStatus.isFresh(live, for: host.id), let occupant = Self.occupant(of: live.state) else {
                return nil
            }
            return occupant
        }
        let live = isStreaming ? lastLaunchAttempt : nil
        let app = live?.host.id == host.id ? live?.app : nil
        let target = app ?? LibraryApp(id: 0, name: name ?? "the running app", hdr: false, hidden: false)
        if let confirm { confirm(target, host); return }
        let alert = NSAlert()
        alert.messageText = "Quit \(target.name) on \(host.displayName)?"
        alert.informativeText = "Unsaved progress may be lost."
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Quit").hasDestructiveAction = true
        NSApp.activate()
        guard alert.runModal() == .alertSecondButtonReturn else { return }
        Task {
            do { try await quitRunningApp(on: host) } catch {
                let failure = NSAlert()
                failure.messageText = "Couldn't quit \(target.name) on \(host.displayName)."
                failure.informativeText = Self.quitFailureMessage(for: error, hostName: host.displayName)
                failure.runModal()
            }
        }
    }
}
