//
//  MutedOutputTests.swift
//
//  The mute crash record: the device that was muted and its level survive a
//  relaunch through UserDefaults, and read back as nil once cleared.
//

import Foundation
import Testing
@testable import Glimmer

struct MutedOutputTests {

    private func scratchDefaults() throws -> UserDefaults {
        let suite = "io.ugfugl.Glimmer.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defaults.removePersistentDomain(forName: suite)
        return defaults
    }

    @Test func recordRoundTrips() throws {
        let defaults = try scratchDefaults()
        let output = MutedOutput(uid: "AppleHDA:Speakers", volume: 0.42)
        AppModel.recordPendingRestore(output, in: defaults)
        #expect(AppModel.pendingRestore(in: defaults) == output)
    }

    @Test func noRecordReadsAsNil() throws {
        #expect(AppModel.pendingRestore(in: try scratchDefaults()) == nil)
    }
}
