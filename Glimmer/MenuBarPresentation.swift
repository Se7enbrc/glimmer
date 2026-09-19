//
//  MenuBarPresentation.swift
//
//  The pure decisions behind the menu bar item: which mark to show, what the
//  first row does, and how a few readings are worded. No AppKit, no model, so
//  every rule has a unit test.
//

import Foundation

enum MenuBarIconState: Equatable {
    case idle, connecting, reconnecting, streaming, attention
}

enum MenuBarPrimaryAction: Equatable {
    case stream(app: String)
    case cancelConnection
    case backToStream
    case none
}

enum MenuBarPresentation {

    static func icon(phase: StreamPhase, reconnecting: Bool, error: String?) -> MenuBarIconState {
        if error != nil { return .attention }
        switch phase {
        case .streaming: return .streaming
        case .connecting: return reconnecting ? .reconnecting : .connecting
        case .disconnecting: return .connecting
        case .idle: return .idle
        case .error: return .attention
        }
    }

    /// SF Symbol for a state; nil keeps the Eclipse mark.
    static func systemImage(for state: MenuBarIconState) -> String? {
        switch state {
        case .idle: nil
        case .connecting: "circle.dotted"
        case .reconnecting: "arrow.trianglehead.clockwise"
        case .streaming: "play.fill"
        case .attention: "exclamationmark.triangle.fill"
        }
    }

    static func accessibilityLabel(state: MenuBarIconState, hostName: String?) -> String {
        let name = hostName ?? "your PC"
        switch state {
        case .idle: return "Glimmer"
        case .connecting: return "Glimmer, connecting to \(name)"
        case .reconnecting: return "Glimmer, reconnecting to \(name)"
        case .streaming: return "Glimmer, streaming to \(name)"
        case .attention: return "Glimmer, needs attention"
        }
    }

    static func primaryAction(phase: StreamPhase, hostSelected: Bool, heroApp: String) -> MenuBarPrimaryAction {
        switch phase {
        case .streaming: return .backToStream
        case .connecting, .disconnecting: return .cancelConnection
        case .idle, .error: return hostSelected ? .stream(app: heroApp) : .none
        }
    }

    static func batteryRow(name: String, percent: Int, charging: Bool) -> String {
        "\(name) · \(percent)%" + (charging ? ", charging" : "")
    }

    /// One word for the selected PC, or nil when the reading is stale or unknown.
    static func readiness(_ state: HostLiveStatus.State?, fresh: Bool) -> String? {
        guard fresh, let state else { return nil }
        switch state {
        case .idle: return "Ready"
        case .streamingApp(let name): return "Busy: \(name)"
        case .streamingUnknownApp: return "Busy"
        case .asleep: return "Asleep"
        case .certMismatch: return "Needs pairing again"
        case .unknown: return "Unavailable"
        }
    }

    /// The section header while streaming, in the launcher's own mode wording.
    static func statusLine(hostName: String, width: Int, height: Int, fps: Int, hdr: Bool) -> String {
        "Streaming to \(hostName) · \(width) × \(height) · \(fps) Hz" + (hdr ? " · HDR" : "")
    }

    /// The header for the selected PC when idle: its name, and its readiness when known.
    static func hostHeader(name: String, readiness: String?) -> String {
        readiness.map { "\(name) · \($0)" } ?? name
    }

    /// The Connection Details rows; each is "Label: value" with a plain unit.
    /// Frames are what arrives, so a hidden window (nothing rendered) still reads true.
    static func detailLines(snapshot: StreamStatsSnapshot?, link: String?) -> [String] {
        guard let snapshot else { return ["Waiting for the first second of video"] }
        var lines: [String] = []
        if let fps = snapshot.receivedFps ?? snapshot.renderedFps {
            lines.append("Frames: \(Int(fps.rounded())) per second")
        }
        if let rtt = snapshot.rttMs { lines.append("Latency: \(Int(rtt.rounded())) ms") }
        if let mbps = snapshot.measuredBitrateMbps ?? snapshot.negotiatedBitrateMbps {
            lines.append("Bitrate: \(Int(mbps.rounded())) Mbps")
        }
        if let link { lines.append("Network: \(link)") }
        return lines
    }

    static func linkLabel(_ route: HostRouteMonitor.RouteClass) -> String? {
        switch route {
        case .wired: "Wired"
        case .wifi: "Wi-Fi"
        case .tunnel: "VPN"
        case .unknown: nil
        }
    }
}
