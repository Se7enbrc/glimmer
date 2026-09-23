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

    /// What the app does with one request. `ready` answers `check`: a stream
    /// request now would be taken.
    enum Decision: Equatable {
        case stream(LibraryApp, on: Host, takeover: Bool)
        case rejected(String)
        case ready
        case stop
        case notMine
    }

    static let alreadyStreaming = "Glimmer is already streaming. Stop Streaming, then try again."

    static func post(_ name: Notification.Name, _ info: [String: String]) {
        DistributedNotificationCenter.default().postNotificationName(
            name, object: nil, userInfo: info, deliverImmediately: true)
    }

    /// The app's rules for a request, without side effects. `handled` holds the
    /// ids already answered, so a repeat gets nil; `streamingFrom` is the PC
    /// this Mac is streaming from or about to, if any.
    static func decide(
        _ info: [String: String], handled: inout Set<String>, hosts: [Host], streamingFrom: String?
    ) -> Decision? {
        guard let id = info[Key.id], let hostID = info[Key.host], handled.insert(id).inserted else { return nil }
        switch info[Key.verb] {
        case "check":
            return streamingFrom == nil ? .ready : .rejected(alreadyStreaming)
        case "stream":
            guard streamingFrom == nil else { return .rejected(alreadyStreaming) }
            let appID = info[Key.app].flatMap { Int($0) }
            guard let host = hosts.first(where: { $0.id == hostID }),
                  let app = host.apps.first(where: { $0.id == appID }) else {
                return .rejected("Glimmer doesn't know that PC or app.")
            }
            return .stream(app, on: host, takeover: info[Key.takeover] == "1")
        case "quit":
            return streamingFrom == hostID ? .stop : .notMine
        default:
            return nil
        }
    }
}

extension AppModel {
    private static var commandObserver: NSObjectProtocol?
    private static var handledCommandIDs: Set<String> = []
    /// The PC of an accepted stream request still waiting for its route.
    private static var commandStreamHostID: String?

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
        // A PC paired from the command line since launch is only in defaults.
        if info[CommandChannel.Key.verb] == "stream" { loadHosts() }
        guard let id = info[CommandChannel.Key.id],
              let decision = CommandChannel.decide(
                info, handled: &Self.handledCommandIDs, hosts: hosts,
                streamingFrom: Self.commandStreamHostID ?? (isStreaming ? lastLaunchAttempt?.host.id : nil))
        else { return }
        switch decision {
        case .stream(let app, let host, let takeover):
            Diag.notice("Stream requested from the command line", "Stream")
            // The terminal settled the takeover; an older unanswered prompt no longer applies.
            pendingTakeover = nil
            selectHost(host)
            Self.commandStreamHostID = host.id
            Task { await streamFromCommand(id, app: app, on: host, takeover: takeover) }
        case .rejected(let why):
            replyToCommand(id, CommandChannel.Event.rejected, why)
        case .ready:
            replyToCommand(id, CommandChannel.Event.accepted)
        case .stop:
            stopForCommand(id)
        case .notMine:
            replyToCommand(id, CommandChannel.Event.notMine)
        }
    }

    /// A new selection re-points the route monitor, and the ask reads its class and,
    /// on Wi-Fi, the radio's PHY rate: give both up to 500 ms (usually one tick).
    private func streamFromCommand(_ id: String, app: LibraryApp, on host: Host, takeover: Bool) async {
        let settled = await Self.poll(slices: 20, every: .milliseconds(25)) {
            Self.routeSettled(hostRoute.routeClass, phyMbps: hostRoute.wifiPhyRateMbps)
        }
        Self.commandStreamHostID = nil
        if !settled {
            Diag.notice(hostRoute.routeClass == .wifi
                ? "No Wi-Fi rate for \(host.displayName) yet; asking without the radio gate"
                : "Route to \(host.displayName) still unknown; asking without a route boost", "Stream")
        }
        guard !isStreaming else {
            replyToCommand(id, CommandChannel.Event.rejected, CommandChannel.alreadyStreaming)
            return
        }
        stream(app: app, on: host, takeoverAuthorized: takeover)
        replyToCommand(id, CommandChannel.Event.accepted)
        reportCommandSession(id)
    }

    /// The ask a launcher click would make is ready: the route is known and, on
    /// Wi-Fi, the radio gate has its first PHY read.
    nonisolated static func routeSettled(_ route: HostRouteMonitor.RouteClass, phyMbps: Double?) -> Bool {
        route != .unknown && (route != .wifi || phyMbps != nil)
    }

    /// Checks `settled` up to `slices` times, `slice` apart, stopping at the first
    /// true answer; false once the budget runs out.
    static func poll(slices: Int, every slice: Duration, until settled: () -> Bool) async -> Bool {
        for _ in 0..<slices {
            if settled() { return true }
            try? await Task.sleep(for: slice)
        }
        return settled()
    }

    /// "notMine" leaves the /cancel to the command line.
    private func stopForCommand(_ id: String) {
        Task {
            let quit = await stopOwnStream(source: "the command line")
            replyToCommand(id, quit ? CommandChannel.Event.stopped : CommandChannel.Event.notMine)
        }
    }

    /// Our stream ends through stop(), which can't trigger a reconnect. True when
    /// that quit the app on the PC too: stop() cancels there only when this
    /// session launched it.
    func stopOwnStream(source: String) async -> Bool {
        guard let session = nativeSession else { return false }
        let owns = await session.ownsHostSession
        stopStreamFromMenu(source: source)
        return owns
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
            let busy = pendingTakeover.map {
                "\($0.host.displayName) is busy. Choose Quit and Stream in Glimmer, or run again with --force."
            }
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
