// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import Testing
#if canImport(GlimmerEngine)
@testable import GlimmerEngine
#endif

// Replays golden vectors recorded from the baseline release (scripts/differential/README.md).
// A case may differ only when its vector carries "accepted" output and the reason it is a fix.
enum CleanRoomGolden {
    struct Vector<Input: Decodable & Sendable, Output: Decodable & Sendable>: Decodable, Sendable {
        let name: String
        let input: Input
        let expected: Output
        let accepted: Output?
        let reason: String?
    }

    struct File<Input: Decodable & Sendable, Output: Decodable & Sendable>: Decodable, Sendable {
        let baseline: String
        let cases: [Vector<Input, Output>]
    }

    private final class ResourceBundle {}

    static func load<Input: Decodable & Sendable, Output: Decodable & Sendable>(_ area: String) throws -> File<Input, Output> {
        let url = try #require(Bundle(for: ResourceBundle.self)
            .url(forResource: area, withExtension: "json", subdirectory: "CleanRoomVectors"))
        return try JSONDecoder().decode(File<Input, Output>.self, from: Data(contentsOf: url))
    }

    // Apple's Opus decoder is shared by both trees; allow float rounding, never a different shape.
    static func matches(_ actual: CleanRoomProbe.AudioOutput, _ golden: CleanRoomProbe.AudioOutput) -> Bool {
        guard actual.created == golden.created, actual.steps.count == golden.steps.count else { return false }
        return zip(actual.steps, golden.steps).allSatisfy { mine, theirs in
            mine.frames == theirs.frames && mine.overrun == theirs.overrun
                && mine.samples.count == theirs.samples.count && mine.rms.count == theirs.rms.count
                && zip(mine.samples, theirs.samples).allSatisfy { abs(Int($0) - Int($1)) <= 2 }
                && zip(mine.rms, theirs.rms).allSatisfy { abs($0 - $1) <= 1e-4 }
        }
    }

    static func describe(_ value: some Encodable) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        return (try? encoder.encode(value)).flatMap { String(bytes: $0, encoding: .utf8) } ?? "?"
    }

    static func check<Output: Encodable>(_ name: String, _ actual: Output, expected: Output, accepted: Output?,
                                         reason: String?, same: (Output, Output) -> Bool) {
        let target = accepted ?? expected
        #expect(accepted == nil || reason?.isEmpty == false, "\(name): an accepted difference needs a reason")
        #expect(same(actual, target), """
            \(name) differs from \(accepted == nil ? "the baseline" : "its accepted fix")
            actual:   \(describe(actual))
            expected: \(describe(target))
            """)
    }
}

@Suite(.serialized)
struct CleanRoomEngineDifferentialTests {
    @Test func surroundDecodingMatchesBaseline() throws {
        let file: CleanRoomGolden.File<CleanRoomProbe.AudioInput, CleanRoomProbe.AudioOutput> =
            try CleanRoomGolden.load("audio")
        #expect(file.cases.count > 20)
        for vector in file.cases {
            CleanRoomGolden.check("audio/\(vector.name)", CleanRoomProbe.observeAudio(vector.input),
                                  expected: vector.expected, accepted: vector.accepted, reason: vector.reason,
                                  same: CleanRoomGolden.matches)
        }
    }

    @Test func annexBRecognitionMatchesBaseline() throws {
        let file: CleanRoomGolden.File<CleanRoomProbe.VideoInput, CleanRoomProbe.VideoOutput> =
            try CleanRoomGolden.load("video")
        #expect(file.cases.count > 100)
        for vector in file.cases {
            CleanRoomGolden.check("video/\(vector.name)", CleanRoomProbe.observeVideo(vector.input),
                                  expected: vector.expected, accepted: vector.accepted, reason: vector.reason,
                                  same: ==)
        }
    }
}
