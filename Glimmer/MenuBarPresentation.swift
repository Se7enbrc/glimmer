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

struct MenuBarMetric: Equatable {
    let value: String
    let label: String
    /// VoiceOver's name for the label when the printed one is shorthand.
    var spokenLabel: String?
}

/// The selected PC as the launcher reads it: its chip and its power state.
struct MenuBarHost: Equatable {
    let chip: ChipPresentation
    let canWake: Bool
    let waking: Bool
}

enum MenuBarPrimaryAction: Equatable {
    case stream(app: String)
    case wake
    case waking
    case pairAgain
    case cancelConnection
    case stopStreaming
    case backToStream
    case none

    /// Try Again only helps when the PC looks able to stream.
    var allowsRetry: Bool {
        if case .stream = self { return true }
        return false
    }
}

/// One pad in the Controller card; a nil percent is a pad with no reading.
struct MenuBarController: Equatable {
    let name: String
    let percent: Int?
    let charging: Bool

    var status: String {
        guard let percent else { return "Connected" }
        return "\(percent)%" + (charging ? ", charging" : "")
    }
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

    /// The launcher's one button, in the menu bar: a sleeping PC wakes, an
    /// untrusted one pairs again, and a reconnect is a stream you can stop.
    static func primaryAction(phase: StreamPhase, reconnecting: Bool, host: MenuBarHost?,
                              heroApp: String) -> MenuBarPrimaryAction {
        switch phase {
        case .streaming: return .backToStream
        case .connecting, .disconnecting: return reconnecting ? .stopStreaming : .cancelConnection
        case .idle, .error:
            guard let host else { return .none }
            if host.waking { return .waking }
            switch host.chip {
            case .certMismatch: return .pairAgain
            case .asleep where host.canWake: return .wake
            default: return .stream(app: heroApp)
            }
        }
    }

    /// GameController's pads, then raw-HID pads it doesn't own, matched by
    /// name the way HIDGamepadManager yields a pad to GameController.
    static func controllers(gameController: [MenuBarController], rawHID: [MenuBarController]) -> [MenuBarController] {
        let owned = Set(gameController.map(\.name))
        return gameController + rawHID.filter { !owned.contains($0.name) }
    }

    /// The takeover question's first line; the running app will quit. Only
    /// the "another app" fallback is capitalized, real names pass through.
    static func takeoverMessage(app: String, pc: String) -> String {
        (app == "another app" ? "Another app" : app) + " is running on \(pc)."
    }

    /// The mode line under the stream card's header, in the launcher's wording.
    static func modeLine(width: Int, height: Int, fps: Int, hdr: Bool) -> String {
        "\(width) × \(height) · \(fps) Hz" + (hdr ? " · HDR" : "")
    }

    /// The big numbers: frames arriving (true even with the window hidden),
    /// latency, bitrate and the network.
    static func metrics(snapshot: StreamStatsSnapshot?, link: String?) -> [MenuBarMetric] {
        var out: [MenuBarMetric] = []
        let fps = snapshot?.receivedFps ?? snapshot?.renderedFps
        out.append(MenuBarMetric(value: fps.map { "\(Int($0.rounded()))" } ?? "–", label: "Frames/s",
                                spokenLabel: "Frames per second"))
        out.append(MenuBarMetric(value: snapshot?.rttMs.map { "\(Int($0.rounded())) ms" } ?? "–", label: "Latency"))
        let mbps = snapshot?.measuredBitrateMbps ?? snapshot?.negotiatedBitrateMbps
        out.append(MenuBarMetric(value: mbps.map { "\(Int($0.rounded())) Mbps" } ?? "–", label: "Bandwidth"))
        out.append(MenuBarMetric(value: link ?? "–", label: "Network"))
        return out
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
