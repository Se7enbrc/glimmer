//
//  AppModel+Commands.swift
//
//  The running app's side of `glimmer stream` and `glimmer quit`: requests
//  arrive over distributed notifications and go through the launcher's own
//  entry points. Also quitting a PC's running app without streaming into it.
//

import AppKit
import Foundation

/// Plain string dictionaries keyed by a request id, posted with immediate
/// delivery so an inactive app still hears them. No URL scheme on purpose:
/// a web page can't start a stream.
enum CommandChannel {
    private static let prefix = Bundle.main.bundleIdentifier ?? "io.ugfugl.Glimmer"
    static let request = Notification.Name(prefix + ".command")
    static let reply = Notification.Name(prefix + ".command-reply")

    enum Key {
        static let id = "id"
        static let verb = "verb"
        static let host = "host"
        static let app = "app"
        static let takeover = "takeover"
        static let event = "event"
        static let detail = "detail"
    }

    enum Event {
        static let accepted = "accepted"
        static let rejected = "rejected"
        static let stopped = "stopped"
        static let notMine = "notMine"
        static let live = "live"
        static let ended = "ended"
    }

    static func post(_ name: Notification.Name, _ info: [String: String]) {
        DistributedNotificationCenter.default().postNotificationName(
            name, object: nil, userInfo: info, deliverImmediately: true)
    }
}

extension AppModel {
    private static var commandObserver: NSObjectProtocol?
    private static var handledCommandIDs: Set<String> = []

    /// Installed once the host list is loaded; the CLI re-posts each second
    /// until it hears back, so a request sent before this is simply repeated.
    func listenForCommands() {
        guard Self.commandObserver == nil else { return }
        Self.commandObserver = DistributedNotificationCenter.default().addObserver(
            forName: CommandChannel.request, object: nil, queue: .main
        ) { [weak self] note in
            guard let info = note.userInfo as? [String: String] else { return }
            MainActor.assumeIsolated { self?.handleCommand(info) }
        }
    }

    func handleCommand(_ info: [String: String]) {
        typealias Key = CommandChannel.Key
        guard let id = info[Key.id], let hostID = info[Key.host],
              Self.handledCommandIDs.insert(id).inserted else { return }
        switch info[Key.verb] {
        case "stream":
            loadHosts()
            let host = hosts.first { $0.id == hostID }
            let appID = info[Key.app].flatMap { Int($0) }
            if let host, let app = host.apps.first(where: { $0.id == appID }), !isStreaming {
                Diag.notice("Stream requested from the command line", "Stream")
                selectHost(host)
                stream(app: app, on: host, takeoverAuthorized: info[Key.takeover] == "1")
                replyToCommand(id, CommandChannel.Event.accepted)
                reportCommandSession(id)
            } else {
                let why = isStreaming ? "Glimmer is already streaming. Stop that stream first."
                    : "Glimmer doesn't know that PC or app."
                replyToCommand(id, CommandChannel.Event.rejected, why)
            }
        case "quit":
            // Our own stream from that PC stops through stop(), which cancels
            // on the host and can't trigger a reconnect; a bare /cancel would.
            let mine = isStreaming && lastLaunchAttempt?.host.id == hostID
            if mine { stopStreamFromMenu(source: "the command line") }
            replyToCommand(id, mine ? CommandChannel.Event.stopped : CommandChannel.Event.notMine)
        default:
            break
        }
    }

    private func replyToCommand(_ id: String, _ event: String, _ detail: String? = nil, extra: [String: String] = [:]) {
        var info = extra
        info[CommandChannel.Key.id] = id
        info[CommandChannel.Key.event] = event
        if let detail { info[CommandChannel.Key.detail] = detail }
        CommandChannel.post(CommandChannel.reply, info)
    }

    /// "live" at the first decoded frame (with the connect timings), then
    /// "ended" with the failure text, if any, once the session is gone.
    private func reportCommandSession(_ id: String) {
        Task { @MainActor in
            var sentLive = false
            while isStreaming {
                if !sentLive, ConnectTimingTelemetry.shared.clickToFirstFrameMs != nil {
                    sentLive = true
                    replyToCommand(id, CommandChannel.Event.live, extra: Self.connectTimings())
                }
                try? await Task.sleep(for: .milliseconds(sentLive ? 1000 : 100))
            }
            let busy = pendingTakeover.map { "\($0.host.displayName) is busy. Choose Take Over in Glimmer, or run again with --force." }
            replyToCommand(id, CommandChannel.Event.ended, nativeStreamError ?? busy)
        }
    }

    /// Click to first frame and the launch legs, in whole milliseconds.
    static func connectTimings() -> [String: String] {
        let timing = ConnectTimingTelemetry.shared
        var legs = HandshakeBreakdown()
        timing.applyLaunchLegs(to: &legs)
        let values: [String: Double?] = [
            "start_to_first_frame_ms": timing.clickToFirstFrameMs,
            "launch_path_ms": timing.launchPathMs,
            "serverinfo_ms": legs.launchServerinfoMs,
            "cancel_ms": legs.launchCancelMs,
            "busy_wait_ms": legs.launchBusyWaitMs,
            "launch_ms": legs.launchMs,
            "build_ms": legs.buildMs
        ]
        return values.compactMapValues { $0.map { String(Int($0.rounded())) } }
    }

    /// Ends whatever the PC is running without streaming into it: /cancel
    /// over the pinned connection, then a fresh readiness poll.
    func quitRunningApp(on host: Host) async throws {
        let info = nativeServerInfo(for: host)
        guard info.serverCertPEM != nil else {
            throw StreamError.pairingFailed("\(host.displayName) isn't paired with this Mac.")
        }
        let client = NetworkClient(server: info)
        defer { restartHostStatusPolling() }
        do {
            try await client.cancel()
            await client.shutdown()
        } catch StreamError.launchFailed {
            await client.shutdown()
            // Older Sunshine answers 503 while another device is connected.
            throw StreamError.launchFailed(
                "\(host.displayName) wouldn't quit the app. If another device is streaming from it, stop that stream first.")
        } catch {
            await client.shutdown()
            throw error
        }
    }
}
