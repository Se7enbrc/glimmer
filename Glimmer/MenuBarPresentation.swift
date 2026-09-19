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

enum MenuBarReadinessTone: Equatable {
    case ready, busy, off, trouble
}

struct MenuBarMetric: Equatable {
    let value: String
    let label: String
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

    /// The mode line under the stream card's header, in the launcher's wording.
    static func modeLine(width: Int, height: Int, fps: Int, hdr: Bool) -> String {
        "\(width) × \(height) · \(fps) Hz" + (hdr ? " · HDR" : "")
    }

    static func readinessTone(_ state: HostLiveStatus.State?) -> MenuBarReadinessTone {
        switch state {
        case .idle: .ready
        case .streamingApp, .streamingUnknownApp: .busy
        case .asleep, .unknown, nil: .off
        case .certMismatch: .trouble
        }
    }

    /// The right-hand word of the stream card's header.
    static func stateWord(_ state: MenuBarIconState, readiness: String?) -> String {
        switch state {
        case .idle: readiness ?? "Idle"
        case .connecting: "Connecting…"
        case .reconnecting: "Reconnecting…"
        case .streaming: "Streaming"
        case .attention: "Needs attention"
        }
    }

    /// The big numbers: frames arriving (true even with the window hidden),
    /// latency, bitrate and the network.
    static func metrics(snapshot: StreamStatsSnapshot?, link: String?) -> [MenuBarMetric] {
        var out: [MenuBarMetric] = []
        let fps = snapshot?.receivedFps ?? snapshot?.renderedFps
        out.append(MenuBarMetric(value: fps.map { "\(Int($0.rounded()))" } ?? "–", label: "Frames/s"))
        out.append(MenuBarMetric(value: snapshot?.rttMs.map { "\(Int($0.rounded())) ms" } ?? "–", label: "Latency"))
        let mbps = snapshot?.measuredBitrateMbps ?? snapshot?.negotiatedBitrateMbps
        out.append(MenuBarMetric(value: mbps.map { "\(Int($0.rounded())) Mbps" } ?? "–", label: "Bandwidth"))
        out.append(MenuBarMetric(value: link ?? "–", label: "Network"))
        return out
    }

    static func batterySymbol(percent: Int, charging: Bool) -> String {
        if charging { return "battery.100percent.bolt" }
        switch percent {
        case ..<10: return "battery.0percent"
        case ..<35: return "battery.25percent"
        case ..<60: return "battery.50percent"
        case ..<85: return "battery.75percent"
        default: return "battery.100percent"
        }
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
