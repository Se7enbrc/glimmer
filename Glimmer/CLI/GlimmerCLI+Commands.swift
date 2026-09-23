//
//  GlimmerCLI+Commands.swift
//
//  `glimmer pair`, `glimmer wake` and `glimmer quit`: the pairing sheet's
//  handshake, the Wake and Connect packets, and /cancel, all headless.
//

import AppKit
import Foundation

extension GlimmerCLI {

    // MARK: pair

    static func pair(_ command: Command, model: AppModel) async -> Int32 {
        let address = command.arguments[0]
        if let known = matchHost(address, in: model.hosts), await isStillPaired(known, model: model) {
            print("Already paired with \(known.displayName).")
            return Exit.ok
        }
        let pin = command.pin ?? model.generatePairingPIN()
        printError("On \(address), open Sunshine's web page, choose PIN, and enter \(pin).")
        let attempt = model.beginPairing(address: address)
        if let host = await model.pair(attempt: attempt, pin: pin) {
            print("Paired with \(host.displayName).")
            return Exit.ok
        }
        printError(model.pairingMessage ?? "Pairing failed.")
        return Exit.failed
    }

    /// Over the pinned connection, so a PC that stopped trusting this Mac
    /// falls through to a fresh pairing instead of "already paired".
    private static func isStillPaired(_ host: Host, model: AppModel) async -> Bool {
        let info = model.nativeServerInfo(for: host)
        guard info.serverCertPEM != nil else { return false }
        let client = NetworkClient(server: info)
        let fetched = try? await client.fetchServerInfo()
        await client.shutdown()
        return fetched?.pairStatus == .paired
    }

    // MARK: wake

    static func wake(_ command: Command, model: AppModel) async -> Int32 {
        guard let host = resolveHost(command.arguments[0], model: model) else { return Exit.notPaired }
        let name = host.displayName
        guard model.canWake(host) else {
            printError("Wake on LAN is off for \(name), or Glimmer hasn't learned its network address yet. "
                + "Connect once while it's awake.")
            return Exit.failed
        }
        let wait = command.flags.contains("--wait")
        if wait { printError("Sending wake packets to \(name) and waiting for it to answer…") }
        switch await model.sendWakeAndWait(host, waitSeconds: wait ? AppModel.wakeBudgetSeconds : nil) {
        case .noMac, .couldNotSend:
            printError("Couldn't send wake packets to \(name). Check this Mac's network.")
            return Exit.failed
        case .sent:
            print("Sent wake packets to \(name).")
            return Exit.ok
        case .answered:
            print("\(name) is awake.")
            return Exit.ok
        case .noAnswer:
            printError("No answer from \(name). \(AppModel.wakeNoAnswerHint)")
            return Exit.unreachable
        }
    }

    // MARK: quit

    static func quit(_ command: Command, model: AppModel) async -> Int32 {
        guard let host = resolveHost(command.arguments[0], model: model) else { return Exit.notPaired }
        let running: String
        switch await probe(host, model: model)?.state {
        case .asleep, nil:
            printError(unreachableMessage(host.displayName))
            return Exit.unreachable
        case .certMismatch:
            printError(notPairedMessage(host))
            return Exit.notPaired
        case .idle, .unknown:
            print("\(host.displayName) isn't running an app.")
            return Exit.ok
        case .streamingApp(let name):
            running = name
        case .streamingUnknownApp:
            running = "the running app"
        }
        // A Glimmer stream from this PC has to end through the app: a /cancel
        // from here would look like a host restart and the stream would relaunch.
        let request = [CommandChannel.Key.verb: "quit", CommandChannel.Key.host: host.id]
        if runningGlimmer() != nil,
           await ask(request, within: .seconds(2))?[CommandChannel.Key.event] == CommandChannel.Event.stopped {
            print("Quit \(running) on \(host.displayName).")
            return Exit.ok
        }
        do {
            try await model.quitRunningApp(on: host)
            print("Quit \(running) on \(host.displayName).")
            return Exit.ok
        } catch {
            printError(message(for: error, host: host))
            return exitCode(for: error)
        }
    }

    /// The Glimmer app, if one is running besides this process.
    static func runningGlimmer() -> NSRunningApplication? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let own = ProcessInfo.processInfo.processIdentifier
        return NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .first { $0.processIdentifier != own }
    }

    /// Opens (or brings forward) the app through Launch Services. Returns its
    /// instance, never this process, or nil after saying why.
    static func openGlimmer() async -> NSRunningApplication? {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        // This process is registered under Glimmer's bundle ID too; with no app
        // running, Launch Services could otherwise "activate" it and launch nothing.
        configuration.createsNewApplicationInstance = runningGlimmer() == nil
        let opened: NSRunningApplication
        do {
            opened = try await NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration)
        } catch {
            printError("Couldn't open Glimmer: \(error.localizedDescription)")
            return nil
        }
        // With the app already open, Launch Services can answer with this process.
        if opened.processIdentifier != ProcessInfo.processInfo.processIdentifier { return opened }
        if let app = runningGlimmer() { return app }
        printError("Couldn't open Glimmer. Open it from the Applications folder and try again.")
        return nil
    }

    /// Posts `request` to the running app each second until it replies or
    /// `timeout` passes. Later replies to the same request arrive on `replies`.
    static func ask(
        _ request: [String: String], within timeout: Duration, replies: CommandReplies? = nil
    ) async -> [String: String]? {
        let id = UUID().uuidString
        let inbox = replies ?? CommandReplies()
        inbox.requestID = id
        var info = request
        info[CommandChannel.Key.id] = id
        let clock = ContinuousClock()
        let deadline = clock.now + timeout
        var nextPost = clock.now
        while clock.now < deadline {
            if let reply = inbox.take() { return reply }
            if clock.now >= nextPost {
                CommandChannel.post(CommandChannel.request, info)
                nextPost = clock.now + .seconds(1)
            }
            try? await Task.sleep(for: .milliseconds(50))
        }
        return inbox.take()
    }
}

/// Replies from the running app to one request, in arrival order.
@MainActor
final class CommandReplies {
    var requestID: String?
    private var pending: [[String: String]] = []
    private var observer: NSObjectProtocol?

    init() {
        observer = DistributedNotificationCenter.default().addObserver(
            forName: CommandChannel.reply, object: nil, queue: .main
        ) { [weak self] note in
            guard let info = note.userInfo as? [String: String] else { return }
            MainActor.assumeIsolated {
                guard let self, info[CommandChannel.Key.id] == self.requestID else { return }
                self.pending.append(info)
            }
        }
    }

    func take() -> [String: String]? {
        pending.isEmpty ? nil : pending.removeFirst()
    }

    /// The next reply, or nil once `giveUp` says to stop waiting.
    func next(giveUp: () -> Bool) async -> [String: String]? {
        while !giveUp() {
            if let reply = take() { return reply }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return take()
    }
}
