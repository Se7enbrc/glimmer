// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

/// Explicit keys and nulls keep automation independent of UI wording and saved-model changes.
enum CommandJSON {
    static func encode(_ fields: [String: Any]) throws -> String {
        var object = fields
        object["version"] = 1
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return String(bytes: data, encoding: .utf8) ?? "{}"
    }

    static func pc(_ host: Host, live: HostLiveStatus?, paired: Bool, defaultID: String?) -> [String: Any] {
        let state = live?.hostID == host.id ? live?.state : nil
        let status: String
        var running: [String: Any]?
        switch state {
        case .idle: status = "ready"
        case .asleep: status = "asleep"
        case .certMismatch: status = "reachable"
        case .streamingApp(let name):
            status = "reachable"
            let matches = host.apps.filter { $0.name == name }
            let id = live?.runningAppID ?? (matches.count == 1 ? matches.first?.id : nil)
            running = ["name": name, "id": id as Any? ?? NSNull()]
        case .streamingUnknownApp(let id):
            status = "reachable"
            running = ["name": NSNull(), "id": id]
        case .unknown, nil: status = "unknown"
        }
        return ["id": host.id, "name": host.displayName, "address": host.manualAddress as Any? ?? NSNull(),
                "paired": paired && state != .certMismatch, "state": status,
                "runningApp": running as Any? ?? NSNull(), "default": host.id == defaultID]
    }

    static func apps(_ apps: [HostApp], runningID: Int) throws -> String {
        try encode(["apps": apps.map {
            ["id": $0.id, "name": $0.name, "hdr": $0.hdrCapable, "hidden": $0.hidden,
             "running": runningID != 0 && $0.id == runningID] as [String: Any]
        }])
    }

    static func status(
        live: Bool, pc: Host? = nil, app: LibraryApp? = nil,
        resolution: (width: Int, height: Int)? = nil, hdr: Bool? = nil, snapshot: StreamStatsSnapshot? = nil
    ) throws -> String {
        let pcValue = pc.map { ["id": $0.id, "name": $0.displayName] }
        let appValue = app.map { ["id": $0.id, "name": $0.name] as [String: Any] }
        let size = resolution.flatMap {
            $0.width > 0 && $0.height > 0 ? ["width": $0.width, "height": $0.height] : nil
        }
        return try encode([
            "live": live, "pc": pcValue as Any? ?? NSNull(), "app": appValue as Any? ?? NSNull(),
            "resolution": size as Any? ?? NSNull(), "fps": finite(snapshot?.configuredFps),
            "hdr": hdr as Any? ?? NSNull(), "codec": snapshot?.videoCodec as Any? ?? NSNull(),
            "bitrateMbps": finite(snapshot?.negotiatedBitrateMbps)
        ])
    }

    private static func finite(_ value: Double?) -> Any {
        guard let value, value.isFinite else { return NSNull() }
        return value
    }
}

extension GlimmerCLI {
    static func status(
        _ command: Command,
        appIsRunning: () -> Bool = { runningGlimmer() != nil },
        send: ([String: String]) async -> [String: String]? = { await ask($0, within: .seconds(3)) }
    ) async -> Int32 {
        do {
            let json: String
            if appIsRunning() {
                let reply = await send([CommandChannel.Key.verb: "status"])
                guard reply?[CommandChannel.Key.event] == CommandChannel.Event.accepted,
                      let detail = reply?[CommandChannel.Key.detail] else {
                    printError("Glimmer didn't answer. Try again.")
                    return Exit.failed
                }
                json = detail
            } else {
                json = try CommandJSON.status(live: false)
            }
            if command.flags.contains("--json") {
                printLine(json)
            } else {
                let object = try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
                printLine(object?["live"] as? Bool == true ? "Streaming." : "Not streaming.")
            }
            return Exit.ok
        } catch {
            printError("Couldn't read the stream status. Try again.")
            return Exit.failed
        }
    }
}

extension AppModel {
    func commandStatusJSON(
        details: @MainActor (StreamSession) async -> (snapshot: StreamStatsSnapshot, overlayShown: Bool,
                                          resolution: (width: Int, height: Int))? = { await $0.menuBarDetails() }
    ) async throws -> String {
        guard isStreaming, let session = nativeSession, let attempt = lastLaunchAttempt else {
            return try CommandJSON.status(live: false)
        }
        let details = await details(session)
        // Teardown or a replacement session can finish while the snapshot crosses actors.
        guard isStreaming, nativeSession === session else { return try CommandJSON.status(live: false) }
        return try CommandJSON.status(
            live: streamPhase == .streaming && !isReconnecting, pc: attempt.host, app: attempt.app,
            resolution: details?.resolution, hdr: details == nil ? nil : nativeHDRActive,
            snapshot: details?.snapshot)
    }
}
