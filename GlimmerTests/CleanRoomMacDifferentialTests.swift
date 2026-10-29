// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import Testing
@testable import Glimmer

@MainActor @Suite(.serialized)
struct CleanRoomMacDifferentialTests {
    private func replay<Input: Decodable & Sendable, Output: Codable & Equatable & Sendable>(
        _ area: String, minimum: Int, _ observe: @MainActor (Input) async -> Output
    ) async throws {
        let file: CleanRoomGolden.File<Input, Output> = try CleanRoomGolden.load(area)
        #expect(file.cases.count >= minimum)
        for vector in file.cases {
            let actual = await observe(vector.input)
            CleanRoomGolden.check("\(area)/\(vector.name)", actual, expected: vector.expected,
                                  accepted: vector.accepted, reason: vector.reason, same: ==)
        }
    }

    @Test func observationCancellationMatchesBaseline() async throws {
        try await replay("observation", minimum: 10, CleanRoomProbe.observeTracking)
    }

    @Test func helperTimeoutsMatchBaseline() async throws {
        try await replay("helper", minimum: 1, CleanRoomProbe.observeHelper)
    }

    @Test func appOverflowMatchesBaseline() async throws {
        try await replay("grid", minimum: 8, CleanRoomProbe.observeGrid)
    }
}
