//
//  GlimmerCLI+Stream.swift
//
//  `glimmer stream <pc> [<app>]`: checks the PC headlessly, settles a
//  takeover in the terminal, then hands the launch to the one Glimmer app so
//  the stream runs with its window and permissions, never a second instance.
//

import AppKit
import Foundation

extension GlimmerCLI {

    private typealias Key = CommandChannel.Key
    private typealias Event = CommandChannel.Event

    static func stream(_ command: Command, model: AppModel) async -> Int32 {
        guard let host = resolveHost(command.arguments[0], model: model) else { return Exit.notPaired }
        let live = await probe(host, model: model)
        switch live?.state {
        case .asleep, nil:
            let hint = model.canWake(host) ? " To wake it: glimmer wake \"\(host.displayName)\" --wait" : ""
            printError(unreachableMessage(host.displayName) + hint)
            return Exit.unreachable
        case .certMismatch:
            printError(notPairedMessage(host))
            return Exit.notPaired
        default:
            break
        }
        guard let app = pickApp(command.arguments.dropFirst().first, on: host, model: model) else {
            return Exit.usage
        }
        var takeover = command.flags.contains("--force")
        if !takeover, let occupant = live.flatMap({ AppModel.occupant(of: $0.state) }) {
            guard confirmTakeover(pc: host.displayName, occupant: occupant, app: app.name) else { return Exit.failed }
            takeover = true
        }
        return await handOff(app: app, host: host, takeover: takeover, command: command)
    }

    /// The named app, ignoring case, or the launcher's hero target (the probe
    /// just selected this PC, so a running app is resumed as it is there).
    private static func pickApp(_ name: String?, on host: Host, model: AppModel) -> LibraryApp? {
        guard let name else {
            if model.heroTargetApp == nil { printError("Glimmer doesn't know any apps on \(host.displayName).") }
            return model.heroTargetApp
        }
        if let app = host.apps.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) { return app }
        let known = host.apps.map(\.name).joined(separator: ", ")
        printError("Glimmer doesn't know “\(name)” on \(host.displayName). Its apps: \(known)")
        return nil
    }

    /// The launcher's takeover question, asked in the terminal. Scripts
    /// can't answer it, so without a terminal they need --force.
    private static func confirmTakeover(pc: String, occupant: String, app: String) -> Bool {
        guard isatty(STDIN_FILENO) == 1 else {
            printError("\(pc) is running \(occupant). Run again with --force to quit it and start \(app).")
            return false
        }
        printError("\(pc) is running \(occupant). Quit it and start \(app)? [y/N] ", newline: false)
        let answer = readLine()?.trimmingCharacters(in: .whitespaces).lowercased()
        return answer == "y" || answer == "yes"
    }

    /// Open (or bring forward) the app through Launch Services, then post the
    /// request until it answers. Returns after the handoff unless asked to wait.
    private static func handOff(app: LibraryApp, host: Host, takeover: Bool, command: Command) async -> Int32 {
        guard let glimmer = await openGlimmer() else { return Exit.failed }
        let replies = CommandReplies()
        let request = [Key.verb: "stream", Key.host: host.id, Key.app: String(app.id), Key.takeover: takeover ? "1" : "0"]
        guard let first = await ask(request, within: .seconds(20), replies: replies) else {
            printError("Glimmer didn't answer. Open it and try again.")
            return Exit.failed
        }
        guard first[Key.event] == Event.accepted else {
            printError(first[Key.detail] ?? "Glimmer couldn't start the stream.")
            return Exit.failed
        }
        let wait = command.flags.contains("--wait")
        let json = command.flags.contains("--json")
        guard wait || json || command.flags.contains("--exit-after-first-frame") else {
            print("Glimmer is starting \(app.name) on \(host.displayName).")
            return Exit.ok
        }
        while let reply = await replies.next(giveUp: { glimmer.isTerminated }) {
            if json { print(jsonLine(reply)) }
            if reply[Key.event] == Event.live, !wait { return Exit.ok }
            if reply[Key.event] == Event.ended {
                guard let detail = reply[Key.detail] else { return Exit.ok }
                printError(detail)
                return Exit.failed
            }
        }
        printError("Glimmer quit before the stream ended.")
        return Exit.failed
    }

    /// One JSON object per event: the `_ms` timings as numbers.
    nonisolated static func jsonLine(_ reply: [String: String]) -> String {
        var object: [String: Any] = [:]
        for (key, value) in reply where key != Key.id {
            if key.hasSuffix("_ms"), let number = Int(value) {
                object[key] = number
            } else {
                object[key] = value
            }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return "{}" }
        return String(bytes: data, encoding: .utf8) ?? "{}"
    }
}
