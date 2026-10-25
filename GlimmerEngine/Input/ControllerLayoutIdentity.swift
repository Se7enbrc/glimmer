// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import CryptoKit
import Foundation

public struct ControllerLayoutIdentity: Codable, Hashable, Sendable {
    public let type: String
    public let hardware: String?

    public init(category: String, profile: String, controls: [String], vendor: UInt16? = nil,
                product: UInt16? = nil, verifiedSerial: String? = nil, salt: Data = Data()) {
        type = Self.digest([category, profile] + Array(Set(controls)).sorted())
        let serial = verifiedSerial?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let placeholders = ["unknown", "none", "null", "0", "00000000", "000000000000"]
        if let vendor, let product, vendor != 0, product != 0, !salt.isEmpty,
           !serial.isEmpty, serial.utf8.count <= 256, !placeholders.contains(serial.lowercased()),
           serial.contains(where: { $0 != "0" && $0 != ":" && $0 != "-" }) {
            hardware = Self.digest([salt.base64EncodedString(), String(vendor), String(product), serial])
        } else {
            hardware = nil
        }
    }

    private static func digest(_ components: [String]) -> String {
        let value = components.map { "\($0.utf8.count):\($0)" }.joined()
        return SHA256.hash(data: Data(value.utf8)).map { String(format: "%02x", $0) }.joined()
    }
}

public enum ControllerLayoutOwner: Codable, Hashable, Sendable {
    case type(String)
    case hardware(String)

    var identifier: String {
        switch self {
        case .type(let value), .hardware(let value): value
        }
    }
}

public enum ControllerLayoutScope: Codable, Hashable, Sendable {
    case allGames
    case game(pcID: String, appID: UInt32)

    func validate() throws {
        if case .game(let pcID, _) = self, pcID.isEmpty || pcID.utf8.count > 256 {
            throw ControllerLayoutError.invalidIdentity
        }
    }
}

public struct ControllerLayoutKey: Codable, Hashable, Sendable {
    public let owner: ControllerLayoutOwner
    public let scope: ControllerLayoutScope

    public init(owner: ControllerLayoutOwner, scope: ControllerLayoutScope) {
        self.owner = owner
        self.scope = scope
    }

    func validate() throws {
        guard owner.identifier.count == 64, owner.identifier.allSatisfy({ $0.isHexDigit }) else {
            throw ControllerLayoutError.invalidIdentity
        }
        try scope.validate()
    }
}

public struct ControllerLayoutRecord: Codable, Equatable, Sendable {
    public let key: ControllerLayoutKey
    public var name: String
    public var layout: ControllerLayout
    public var controls: [ControllerLayoutControl]
    public var category: String?

    public init(key: ControllerLayoutKey, name: String, layout: ControllerLayout,
                controls: [ControllerLayoutControl] = [], category: String? = nil) {
        self.key = key
        self.name = name
        self.layout = layout
        self.controls = controls
        self.category = category
    }
}

public struct ControllerLayoutLibrary: Codable, Equatable, Sendable {
    public var version = 1
    public private(set) var records: [ControllerLayoutRecord]
    public private(set) var shortcuts: [ControllerShortcutRecord]
    public var games: [ControllerLayoutGameRecord] = []

    public init(records: [ControllerLayoutRecord] = [], shortcuts: [ControllerShortcutRecord] = []) {
        self.records = records
        self.shortcuts = shortcuts
    }

    public func resolve(_ identity: ControllerLayoutIdentity, scope: ControllerLayoutScope) -> ControllerLayoutRecord? {
        let owners = identity.hardware.map { [ControllerLayoutOwner.hardware($0), .type(identity.type)] }
            ?? [.type(identity.type)]
        let scopes = scope == .allGames ? [scope] : [scope, .allGames]
        for owner in owners {
            for scope in scopes {
                if let record = records.first(where: { $0.key == .init(owner: owner, scope: scope) }) { return record }
            }
        }
        return nil
    }

    public mutating func save(_ record: ControllerLayoutRecord) throws {
        var copy = self
        copy.records.removeAll { $0.key == record.key }
        copy.records.append(record)
        try copy.validate()
        self = copy
    }

    public mutating func remove(_ key: ControllerLayoutKey) { records.removeAll { $0.key == key } }

    public mutating func removeShortcuts(for owner: ControllerLayoutOwner) { shortcuts.removeAll { $0.owner == owner } }

    public func shortcuts(for identity: ControllerLayoutIdentity) -> ControllerLayoutShortcuts? {
        if let hardware = identity.hardware,
           let record = shortcuts.first(where: { $0.owner == .hardware(hardware) }) { return record.shortcuts }
        return shortcuts.first { $0.owner == .type(identity.type) }?.shortcuts
    }

    public mutating func saveShortcuts(_ record: ControllerShortcutRecord) throws {
        var copy = self
        copy.shortcuts.removeAll { $0.owner == record.owner }
        copy.shortcuts.append(record)
        try copy.validate()
        self = copy
    }

    public func validate() throws {
        guard version == 1 else { throw ControllerLayoutError.unsupportedVersion }
        guard records.count <= 512, Set(records.map(\.key)).count == records.count else {
            throw ControllerLayoutError.invalidDocument
        }
        for record in records {
            try record.key.validate()
            guard record.name.utf8.count <= 256, (record.category?.utf8.count ?? 0) <= 256 else {
                throw ControllerLayoutError.invalidDocument
            }
            try record.layout.validate()
            try ControllerLayout(bindings: record.controls.map { .init($0.id, .disabled) }).validate()
            guard record.controls.allSatisfy({ $0.name.utf8.count <= 256 && $0.symbol.utf8.count <= 128 }) else {
                throw ControllerLayoutError.invalidDocument
            }
        }
        guard shortcuts.count <= 512, Set(shortcuts.map(\.owner)).count == shortcuts.count else {
            throw ControllerLayoutError.invalidDocument
        }
        for record in shortcuts {
            try ControllerLayoutKey(owner: record.owner, scope: .allGames).validate()
            guard record.available.count <= 256 else { throw ControllerLayoutError.invalidBindings }
            try record.shortcuts.validate(available: record.available)
        }
        guard games.count <= 1024, Set(games.map(\.id)).count == games.count else {
            throw ControllerLayoutError.invalidDocument
        }
        for game in games {
            try game.id.validate()
            guard game.name.utf8.count <= 256, game.pcName.utf8.count <= 256 else {
                throw ControllerLayoutError.invalidDocument
            }
        }
    }
}

public struct ControllerShortcutRecord: Codable, Equatable, Sendable {
    public let owner: ControllerLayoutOwner
    public let shortcuts: ControllerLayoutShortcuts
    public let available: Set<ControllerLayoutSource>

    public init(owner: ControllerLayoutOwner, shortcuts: ControllerLayoutShortcuts, available: Set<ControllerLayoutSource>) {
        self.owner = owner
        self.shortcuts = shortcuts
        self.available = available
    }
}
