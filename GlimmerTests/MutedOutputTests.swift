//
//  MutedOutputTests.swift
//
//  "Play sound on the PC": the launch field Sunshine reads, and recovery of a
//  system volume an older build zeroed.
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

    /// The record exactly as a build that still zeroed the system volume wrote it.
    private func writeOlderBuildRecord(_ output: MutedOutput, to defaults: UserDefaults) throws {
        defaults.set(try JSONEncoder().encode(output), forKey: AppModel.mutePendingRestoreKey)
    }

    @Test func olderBuildRecordReadsBack() throws {
        let defaults = try scratchDefaults()
        let output = MutedOutput(uid: "AppleHDA:Speakers", volume: 0.42)
        try writeOlderBuildRecord(output, to: defaults)
        #expect(AppModel.pendingRestore(in: defaults) == output)
    }

    @Test func noRecordReadsAsNil() throws {
        #expect(AppModel.pendingRestore(in: try scratchDefaults()) == nil)
    }

    /// Consumed even when its device is gone, so recovery can't repeat every launch.
    @Test func recoveryConsumesTheRecord() throws {
        let defaults = try scratchDefaults()
        try writeOlderBuildRecord(MutedOutput(uid: "glimmer-tests-no-such-device", volume: 0.5), to: defaults)
        AppModel.restoreOrphanedMute(in: defaults)
        #expect(AppModel.pendingRestore(in: defaults) == nil)
    }

    /// Sunshine keeps the PC's own sound only when asked with localAudioPlayMode=1.
    @Test func playAudioOnHostReachesTheLaunchQuery() {
        var config = StreamConfig(width: 1920, height: 1080, fps: 60, bitrateKbps: 20_000)
        func mode() -> String? {
            NetworkClient.launchQuery(config: config, riKeyHex: "00", riKeyID: 0, appID: 1)["localAudioPlayMode"]
        }
        #expect(mode() == "0")
        config.playAudioOnHost = true
        #expect(mode() == "1")
    }
}
