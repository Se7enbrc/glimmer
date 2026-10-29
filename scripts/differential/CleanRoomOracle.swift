// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import Testing

// Injected into the baseline tree only. generate.sh appends the area list and runs this one suite.
@MainActor
struct CleanRoomOracle {
    @Test func emitObservations() async throws {
        let environment = ProcessInfo.processInfo.environment
        let corpus = URL(filePath: try #require(environment["CLEANROOM_CORPUS"]))
        let output = URL(filePath: try #require(environment["CLEANROOM_OUT"]))
        for area in cleanRoomOracleAreas {
            let input = try Data(contentsOf: corpus.appending(path: "\(area.name).json"))
            try await area.observe(input).write(to: output.appending(path: "\(area.name).json"))
        }
    }
}
