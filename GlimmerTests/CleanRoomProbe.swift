// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

// Observes clean-room regions as data. The same source runs against a baseline tag out of tree,
// so it may only call APIs both trees share; scripts/differential/README.md explains the flow.
enum CleanRoomProbe {
    struct Case<Input: Codable & Sendable>: Codable, Sendable {
        let name: String
        let input: Input
    }

    // One area: decodes its corpus, observes each case and returns the observations by case name.
    struct Area: Sendable {
        let name: String
        let observe: @MainActor @Sendable (Data) async throws -> Data
    }

    static func area<Input: Codable & Sendable, Output: Codable>(
        _ name: String, _ observe: @escaping @MainActor @Sendable (Input) async -> Output
    ) -> Area {
        Area(name: name) { corpus in
            let cases = try JSONDecoder().decode([Case<Input>].self, from: corpus)
            var results: [String: Output] = [:]
            for item in cases { results[item.name] = await observe(item.input) }
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            return try encoder.encode(results)
        }
    }

    static func bytes(hex: String) -> [UInt8] {
        var result: [UInt8] = []
        var index = hex.startIndex
        while let next = hex.index(index, offsetBy: 2, limitedBy: hex.endIndex), next > index {
            result.append(UInt8(hex[index..<next], radix: 16) ?? 0)
            index = next
        }
        return result
    }

    static func hex<Bytes: Sequence>(_ bytes: Bytes) -> String where Bytes.Element == UInt8 {
        bytes.map { String(format: "%02x", $0) }.joined()
    }
}
