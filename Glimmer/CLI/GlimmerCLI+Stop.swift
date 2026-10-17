// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

enum CommandStopResult: String {
    case stopped, noActiveStream, pcMismatch

    var message: String {
        switch self {
        case .stopped: "Stream stopped."
        case .noActiveStream: "No active stream."
        case .pcMismatch: "That PC isn't the active stream. Run “glimmer status --json” to see the current PC."
        }
    }
}

extension GlimmerCLI {
    static func stop(
        _ command: Command,
        appIsRunning: () -> Bool = { runningGlimmer() != nil },
        send: ([String: String]) async -> [String: String]? = { await ask($0, within: .seconds(15)) }
    ) async -> Int32 {
        let result: CommandStopResult
        if appIsRunning() {
            var request = [CommandChannel.Key.verb: "stop"]
            request[CommandChannel.Key.pc] = command.arguments.first
            let reply = await send(request)
            guard let event = reply?[CommandChannel.Key.event], let outcome = CommandStopResult(rawValue: event) else {
                printError("Glimmer didn't answer. Try again.")
                return Exit.failed
            }
            result = outcome
        } else {
            result = .noActiveStream
        }
        if result == .pcMismatch {
            let pc = command.arguments.first ?? "the requested PC"
            printError("Glimmer isn't streaming from “\(pc)”. Run “glimmer status --json” to see the current PC.")
            return Exit.failed
        }
        if command.flags.contains("--json") {
            do {
                printLine(try CommandJSON.encode(["stopped": result == .stopped, "result": result.rawValue]))
            } catch {
                printError("Couldn't report the stop result. Run “glimmer status --json” to check the stream.")
                return Exit.failed
            }
        } else {
            printLine(result.message)
        }
        return result == .stopped ? Exit.ok : Exit.noActiveStream
    }
}
