// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

public struct GlimmerCommandURL: Equatable, Sendable {
    public enum Action: String, Sendable { case stream, stop, wake, quit }
    public let action: Action
    public let pc: String?
    public let app: String?

    public static func parse(_ url: URL) -> Self? {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == "glimmer", parts.user == nil, parts.password == nil,
              parts.port == nil, parts.path.isEmpty, parts.fragment == nil,
              let verb = parts.host.flatMap(Action.init(rawValue:)) else { return nil }
        var values: [String: String] = [:]
        for item in parts.queryItems ?? [] {
            guard item.name == "pc" || (verb == .stream && item.name == "app"),
                  values[item.name] == nil, let value = item.value,
                  !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  !value.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) })
            else { return nil }
            values[item.name] = value
        }
        guard verb == .stop || values["pc"] != nil else { return nil }
        return Self(action: verb, pc: values["pc"], app: values["app"])
    }
}

public enum CommandStopResult: String, Sendable {
    case stopped, noActiveStream, pcMismatch

    public var message: String {
        switch self {
        case .stopped: "Stream stopped."
        case .noActiveStream: "No active stream."
        case .pcMismatch: "That PC isn't the active stream."
        }
    }
}

public enum StreamCommandMatch {
    public static let alreadyStreaming = "Glimmer is already streaming. Stop Streaming, then try again."

    public static func pc(_ query: String, names: [String?]) -> Bool {
        names.compactMap { $0 }.contains { $0.caseInsensitiveCompare(query) == .orderedSame }
    }

    public static func app<Value>(_ name: String, in apps: [Value], name key: KeyPath<Value, String>) -> Value? {
        let wanted = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return apps.first { $0[keyPath: key] == wanted }
            ?? apps.first { $0[keyPath: key].compare(wanted,
                options: [.caseInsensitive, .diacriticInsensitive]) == .orderedSame }
    }
}
