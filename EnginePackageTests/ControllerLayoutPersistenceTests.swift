// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import GlimmerEngine
import Testing

struct ControllerLayoutPersistenceTests {
    private func identity(serial: String? = nil, controls: [String] = ["a", "b"]) -> ControllerLayoutIdentity {
        .init(category: "Xbox", profile: "extended", controls: controls, vendor: 1118, product: 2835,
              verifiedSerial: serial, salt: Data("local-install-salt".utf8))
    }

    private func record(_ owner: ControllerLayoutOwner, _ scope: ControllerLayoutScope,
                        button: ControllerMappedButton = .a) -> ControllerLayoutRecord {
        .init(key: .init(owner: owner, scope: scope), name: "Controller",
              layout: .init(bindings: [.init(.button(.a), .button(button))]))
    }

    @Test func identityIgnoresControlOrderingAndRejectsPlaceholderSerials() {
        #expect(identity().type == identity(controls: ["b", "a", "b"]).type)
        #expect(identity(serial: "unknown").hardware == nil)
        #expect(identity(serial: "000000000000").hardware == nil)
        #expect(identity(serial: "00:00:00:00:00:00").hardware == nil)
        #expect(identity(serial: "one").hardware != identity(serial: "two").hardware)
        #expect(identity(serial: "one").type == identity(serial: "two").type)
    }

    @Test func resolutionUsesHardwareBeforeTypeAndGameBeforeDefault() throws {
        let identity = identity(serial: "unique-device")
        let hardware = try #require(identity.hardware)
        let game = ControllerLayoutScope.game(pcID: "pc-one", appID: 42)
        let ordered = [record(.hardware(hardware), game, button: .x),
                       record(.hardware(hardware), .allGames, button: .y),
                       record(.type(identity.type), game, button: .b),
                       record(.type(identity.type), .allGames)]
        var library = ControllerLayoutLibrary(records: ordered.reversed())
        for expected in ordered {
            #expect(library.resolve(identity, scope: game) == expected)
            library.remove(expected.key)
        }
        #expect(library.resolve(identity, scope: game) == nil)
    }

    @Test func sameAppIDOnAnotherPCDoesNotMatch() {
        let identity = identity()
        let library = ControllerLayoutLibrary(records: [record(.type(identity.type), .game(pcID: "one", appID: 7))])
        #expect(library.resolve(identity, scope: .game(pcID: "two", appID: 7)) == nil)
    }

    @Test func gameCopiesSurviveDefaultEditsAndResets() throws {
        let identity = identity()
        let defaults = record(.type(identity.type), .allGames)
        let game = record(.type(identity.type), .game(pcID: "pc", appID: 1))
        var library = ControllerLayoutLibrary(records: [defaults, game])
        try library.save(record(.type(identity.type), .allGames, button: .b))
        #expect(library.resolve(identity, scope: game.key.scope) == game)
        library.remove(defaults.key)
        #expect(library.resolve(identity, scope: game.key.scope) == game)
        library.remove(game.key)
        #expect(library.resolve(identity, scope: game.key.scope) == nil)
    }

    @Test func localStoreRoundTripsAndRejectsFutureVersionsWithoutReplacingValidData() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = ControllerLayoutStore(url: directory.appendingPathComponent("layouts.json"))
        #expect(try await store.load().records.isEmpty)
        let library = ControllerLayoutLibrary(records: [record(.type(identity().type), .allGames)])
        try await store.save(library)
        #expect(try await store.load() == library)
        var future = library
        future.version = 99
        await #expect(throws: ControllerLayoutError.unsupportedVersion) { try await store.save(future) }
        #expect(try await store.load() == library)
    }

    @Test func duplicateKeysAndUnboundedDocumentsAreRejected() {
        let value = record(.type(identity().type), .allGames)
        #expect(throws: ControllerLayoutError.invalidDocument) {
            try ControllerLayoutLibrary(records: [value, value]).validate()
        }
        #expect(throws: ControllerLayoutError.invalidDocument) {
            try ControllerLayoutLibrary(records: Array(repeating: value, count: 513)).validate()
        }
    }

    @Test func olderRecordsWithoutCategoryStillLoad() throws {
        let value = record(.type(identity().type), .allGames)
        let data = try JSONEncoder().encode(value)
        let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(object["category"] == nil)
        #expect(try JSONDecoder().decode(ControllerLayoutRecord.self, from: data) == value)
    }

    @Test func olderControlMetadataWithoutPositionStillLoads() throws {
        let control = ControllerLayoutControl(id: .extra("unknown"), name: "Extra button", symbol: "button.horizontal")
        let encoded = try JSONEncoder().encode(control)
        let object = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect(object["position"] == nil)
        #expect(try JSONDecoder().decode(ControllerLayoutControl.self, from: encoded) == control)
    }

    @Test func disconnectedControlNamesAndGlyphsSurvivePersistence() throws {
        var record = record(.type(identity().type), .allGames)
        record.category = "DualSense"
        record.controls = [.init(id: .button(.a), name: "Cross", symbol: "xmark.circle"),
                           .init(id: .extra("rear"), name: "Left rear button", symbol: "1.circle", position: .backLeftPrimary)]
        let library = ControllerLayoutLibrary(records: [record])
        try library.validate()
        let data = try JSONEncoder().encode(library)
        #expect(try JSONDecoder().decode(ControllerLayoutLibrary.self, from: data) == library)
    }
}
