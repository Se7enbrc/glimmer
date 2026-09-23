//
//  GlimmerCLI.swift
//
//  `glimmer <verb> ...`: moonlight-style commands run by the app binary itself,
//  headless, through the app's own model. Text goes to stdout and stderr, the
//  result to the exit code. Verbs live in GlimmerCLI+*.swift.
//

import AppKit
import Foundation

@MainActor
enum GlimmerCLI {

    enum Verb: String, Sendable {
        case pair, list, stream, quit, wake, help
    }

    /// Exit codes shared by every verb.
    enum Exit {
        static let ok: Int32 = 0
        static let failed: Int32 = 1
        static let usage: Int32 = 2
        static let unreachable: Int32 = 3
        static let notPaired: Int32 = 4
    }

    struct Command: Equatable, Sendable {
        let verb: Verb
        var arguments: [String] = []
        var flags: Set<String> = []
        var pin: String?
    }

    struct UsageError: Error, Equatable {
        let message: String
    }

    nonisolated private static let allowedFlags: [Verb: Set<String>] = [
        .list: ["--csv"],
        .stream: ["--force", "--wait", "--exit-after-first-frame", "--json"],
        .wake: ["--wait"]
    ]

    nonisolated private static let arity: [Verb: ClosedRange<Int>] = [
        .pair: 1...1, .list: 0...1, .stream: 1...2, .quit: 1...1, .wake: 1...1, .help: 0...1
    ]

    nonisolated static let usage = """
        Usage: glimmer <command> [options]

        Commands:
          pair <address> [--pin NNNN]    Pair with a PC running Sunshine
          list [<pc>] [--csv]            List paired PCs, or the apps on one PC
          stream <pc> [<app>]            Stream an app in Glimmer (default: the running app,
                                         else Settings › General › Default action)
            --force                      Quit an app already running on the PC without asking
            --wait                       Return when the stream ends
            --exit-after-first-frame     Return when the first frame arrives
            --json                       Print connect timings as one JSON line
          quit <pc>                      Quit the app running on a PC
          wake <pc> [--wait]             Send Wake on LAN, and wait for the PC to answer
          help                           Show this help

        <pc> is a paired PC's name or address. Run glimmer with no command to open the app.
        Exit status: 0 success, 1 failure, 2 usage error, 3 PC unreachable, 4 PC not paired.
        """

    /// Run as `glimmer` (the cask's link), it's always the CLI; otherwise a bare
    /// word or -h/--help is. Login, Launch Services, Sparkle, Xcode and tests run
    /// `.../MacOS/Glimmer` with dashed arguments or none, so they reach the app.
    nonisolated static func isInvocation(_ argv: [String]) -> Bool {
        if let name = argv.first, (name as NSString).lastPathComponent == "glimmer" { return true }
        guard argv.count > 1 else { return false }
        return !argv[1].hasPrefix("-") || argv[1] == "--help" || argv[1] == "-h"
    }

    /// Parse the arguments after argv[0]. `--help` anywhere asks for help.
    nonisolated static func parse(_ args: [String]) throws -> Command {
        guard let first = args.first else { throw UsageError(message: usage) }
        if args.contains("--help") || args.contains("-h") { return Command(verb: .help) }
        guard let verb = Verb(rawValue: first) else {
            throw UsageError(message: "Unknown command “\(first)”. Run “glimmer help” for the list.")
        }
        var command = Command(verb: verb)
        var rest = args.dropFirst()
        while let arg = rest.popFirst() {
            if verb == .pair, arg == "--pin" {
                command.pin = rest.popFirst()
                guard let pin = command.pin, pin.count == 4, pin.allSatisfy({ $0.isASCII && $0.isNumber }) else {
                    throw UsageError(message: "The PIN must be four digits.")
                }
            } else if arg.hasPrefix("-") {
                guard allowedFlags[verb]?.contains(arg) == true else {
                    throw UsageError(message: "“glimmer \(verb.rawValue)” doesn't take \(arg).")
                }
                command.flags.insert(arg)
            } else {
                command.arguments.append(arg)
            }
        }
        guard arity[verb]?.contains(command.arguments.count) == true else {
            throw UsageError(message: "Wrong arguments for “glimmer \(verb.rawValue)”. Run “glimmer help”.")
        }
        return command
    }

    /// Run on the main run loop so network callbacks and distributed
    /// notifications arrive; the verb's exit code ends the process.
    static func start(arguments: [String]) {
        // Line by line even into a pipe, so a script reads `--json` events live.
        setvbuf(stdout, nil, _IOLBF, 0)
        Task {
            exit(await run(arguments))
        }
        RunLoop.main.run()
    }

    static func run(_ args: [String]) async -> Int32 {
        // `glimmer` on its own opens the one app, never a copy in this process.
        guard !args.isEmpty else { return await openGlimmer() == nil ? Exit.failed : Exit.ok }
        let command: Command
        do {
            command = try parse(args)
        } catch {
            printError((error as? UsageError)?.message ?? usage)
            return Exit.usage
        }
        if command.verb == .help {
            print(usage)
            return Exit.ok
        }
        // The app's launch order minus the UI. AppModel reads the screen, which
        // registers this process with the window server as Glimmer, so first
        // keep it out of the Dock and Cmd-Tab.
        NSApplication.shared.setActivationPolicy(.prohibited)
        GlimmerApp.prepareDefaults()
        let model = AppModel()
        model.migrateFromMoonlightQtIfNeeded()
        model.loadHosts()
        // The restored selection starts the launcher's poll loop; verbs probe on demand.
        model.hostStatusTask?.cancel()
        switch command.verb {
        case .pair: return await pair(command, model: model)
        case .list: return await list(command, model: model)
        case .stream: return await stream(command, model: model)
        case .quit: return await quit(command, model: model)
        case .wake: return await wake(command, model: model)
        case .help: return Exit.ok
        }
    }

    // MARK: - Shared helpers

    static func printError(_ line: String, newline: Bool = true) {
        FileHandle.standardError.write(Data((line + (newline ? "\n" : "")).utf8))
    }

    /// A paired PC by name, id or address, ignoring case (moonlight's rule).
    nonisolated static func matchHost(_ query: String, in hosts: [Host]) -> Host? {
        hosts.first { host in
            [host.displayName, host.name, host.id, host.localAddress, host.manualAddress]
                .compactMap { $0 }
                .contains { $0.caseInsensitiveCompare(query) == .orderedSame }
        }
    }

    static func resolveHost(_ query: String, model: AppModel) -> Host? {
        if let host = matchHost(query, in: model.hosts) { return host }
        printError("No paired PC matches “\(query)”. Run “glimmer list” to see them, or pair it with “glimmer pair”.")
        return nil
    }

    /// One readiness probe through the launcher's own poller, in place of the loop
    /// a selection starts. A first poll that learns the PC's MAC reloads the host
    /// list and resets the selection, dropping its result; one retry covers that.
    static func probe(_ host: Host, model: AppModel) async -> HostLiveStatus? {
        for _ in 0..<2 {
            model.selectedHost = model.hosts.first { $0.id == host.id } ?? host
            model.hostStatusTask?.cancel()
            model.hostLiveStatus = nil
            _ = await model.pollHostStatusOnce(for: host.id, appListFor: nil)
            if let live = model.hostLiveStatus, live.hostID == host.id { return live }
        }
        return nil
    }

    /// The exit code for a failed request to a PC.
    nonisolated static func exitCode(for error: Error) -> Int32 {
        guard let streamError = error as? StreamError else { return Exit.failed }
        switch streamError {
        case .hostUnreachable(let detail):
            return detail.contains("cert") ? Exit.notPaired : Exit.unreachable
        case .pairingFailed, .pairingRejected:
            return Exit.notPaired
        case .truncatedRead, .sessionFailed:
            return Exit.unreachable
        case .binaryNotFound, .launchFailed, .decoderFailed, .audioFailed, .crypto,
             .streamPortsBlocked, .hostTimedOut, .hostRefused:
            return Exit.failed
        }
    }

    /// One sentence for a failed request, pointing at the command that fixes it.
    nonisolated static func message(for error: Error, host: Host) -> String {
        let name = host.displayName
        if case .hostUnreachable(let detail) = error as? StreamError, detail.contains("Restart Sunshine") {
            return detail
        }
        switch exitCode(for: error) {
        case Exit.unreachable: return AppModel.unreachableMessage(name)
        case Exit.notPaired: return notPairedMessage(host)
        default:
            if case .launchFailed(let detail) = error as? StreamError { return detail }
            return (error as? StreamError)?.description ?? error.localizedDescription
        }
    }

    nonisolated static func notPairedMessage(_ host: Host) -> String {
        "\(host.displayName) needs pairing again. Run: glimmer pair \(AppModel.routeAddress(host))"
    }
}
