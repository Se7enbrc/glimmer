//
//  LogStoreTests.swift
//
//  The troubleshooting ring: wrap order, the pinned session opening, and which levels it keeps.
//

import Foundation
import Testing
@testable import Glimmer

struct LogStoreTests {

    private static func log(_ store: LogStore, _ lines: [String], level: LogLevel = .info) {
        for line in lines { store.log(level, "\(line)", category: "Tests") }
    }

    private static func messages(_ store: LogStore) -> [String] {
        store.snapshot().map(\.message)
    }

    @Test func wrapKeepsTheNewestInOrder() {
        let store = LogStore(capacity: 4, pinnedCapacity: 0, captureDebug: false)
        Self.log(store, (0..<10).map(String.init))
        #expect(Self.messages(store) == ["6", "7", "8", "9"])
    }

    @Test func sessionOpeningSurvivesEvictionWithoutRepeats() {
        let store = LogStore(capacity: 4, pinnedCapacity: 2, captureDebug: false)
        Self.log(store, ["0", "1", "2"])
        #expect(Self.messages(store) == ["0", "1", "2"])
        Self.log(store, (3..<10).map(String.init))
        #expect(Self.messages(store) == ["0", "1", "6", "7", "8", "9"])
        let ids = store.snapshot().map(\.id)
        #expect(ids == ids.sorted())
    }

    @Test func eachSessionPinsItsOwnOpening() {
        let store = LogStore(capacity: 4, pinnedCapacity: 2, captureDebug: false)
        Self.log(store, (0..<10).map { "a\($0)" })
        store.beginSession(captureDebug: false)
        Self.log(store, (0..<10).map { "b\($0)" })
        #expect(Self.messages(store) == ["b0", "b1", "b6", "b7", "b8", "b9"])
    }

    @Test func debugLinesNeedVerboseCapture() {
        let store = LogStore(capacity: 8, pinnedCapacity: 2, captureDebug: false)
        Self.log(store, ["quiet"], level: .debug)
        Self.log(store, ["kept"])
        #expect(Self.messages(store) == ["kept"])
        store.beginSession(captureDebug: true)
        Self.log(store, ["verbose"], level: .debug)
        #expect(Self.messages(store) == ["kept", "verbose"])
    }

    @Test func clearEmptiesThePinsButNeverReusesAnID() {
        let store = LogStore(capacity: 4, pinnedCapacity: 2, captureDebug: false)
        Self.log(store, (0..<6).map(String.init))
        let lastID = store.snapshot().last?.id
        store.clear()
        #expect(store.snapshot().isEmpty)
        Self.log(store, ["after"])
        let entry = store.snapshot().first
        #expect(entry?.message == "after")
        #expect((entry?.id ?? 0) > (lastID ?? .max))
    }
}
