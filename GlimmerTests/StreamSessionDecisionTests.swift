//
//  StreamSessionDecisionTests.swift
//
//  The present watchdog's trip flags and staged recovery, the pacer re-enable
//  gate, the backend config mapping and the attempt guard, on a fake backend.
//

import Foundation
import Testing
@testable import Glimmer

@MainActor @Suite(.serialized)
struct PresentRecoveryLadderTests {
    private let recorder = InputRecordingBackend()

    private func makeSession() -> (StreamSession, VideoDecoder) {
        StreamSession.presentTripsInCluster = 0
        StreamSession.presentTripLastClearedAt = .nan
        let decoder = VideoDecoder()
        decoder.backend = recorder
        return (StreamSession(backend: recorder), decoder)
    }

    private func trip(
        linkDead: Bool = false, stalled: Bool = false, rejecting: Bool = false
    ) -> StreamSession.PresentTrip {
        StreamSession.PresentTrip(
            linkDead: linkDead, presentStalled: stalled, tickDeficit: false,
            rendererRejecting: rejecting, rendererStarved: false)
    }

    @Test func wedgedGateForcesReleaseThenRebuildsWithoutAKeyframe() {
        let (session, decoder) = makeSession()
        let wedged = trip(stalled: true)
        session.escalatePresentRecovery(dec: decoder, trip: wedged, stalledFor: 0.3)
        #expect(session.lastPresentRecoveryStage == 1)
        session.escalatePresentRecovery(dec: decoder, trip: wedged, stalledFor: 0.6)
        #expect(session.lastPresentRecoveryStage == 2)
        session.escalatePresentRecovery(dec: decoder, trip: wedged, stalledFor: 0.9)
        #expect(session.lastPresentRecoveryStage == 2)
        #expect(recorder.idrRequests == 0)
        #expect(session.pacingGiveUpCount == 0)
    }

    /// A refusing renderer gets the flush and keyframe, twice, before the give-up.
    @Test func refusingRendererGetsTheFlushMedicineTwice() {
        let (session, decoder) = makeSession()
        let refusing = trip(stalled: true, rejecting: true)
        session.escalatePresentRecovery(dec: decoder, trip: refusing, stalledFor: 0.3)
        #expect(session.lastPresentRecoveryStage == 1)
        #expect(recorder.idrRequests == 1)
        session.escalatePresentRecovery(dec: decoder, trip: refusing, stalledFor: 0.6)
        #expect(session.lastPresentRecoveryStage == 2)
        #expect(recorder.idrRequests == 2)
        session.escalatePresentRecovery(dec: decoder, trip: refusing, stalledFor: 0.9)
        #expect(recorder.idrRequests == 2)
    }

    @Test func deadLinkGoesStraightToDrainAndRebuild() {
        let (session, decoder) = makeSession()
        session.escalatePresentRecovery(
            dec: decoder, trip: trip(linkDead: true, rejecting: true), stalledFor: 0.3)
        #expect(session.lastPresentRecoveryStage == 2)
        #expect(recorder.idrRequests == 0)
    }

    @Test func giveUpEndsTheEpisodeAndArmsTheReenableOnce() {
        let (session, decoder) = makeSession()
        session.presentStallSince = CFAbsoluteTimeGetCurrent()
        let threshold = StreamSession.presentGiveUpThreshold
        session.escalatePresentRecovery(dec: decoder, trip: trip(stalled: true), stalledFor: threshold)
        #expect(session.lastPresentRecoveryStage == 3)
        #expect(session.pacingGiveUpCount == 1)
        #expect(session.presentStallSince == nil)
        #expect(session.pacingDisabledSince != nil)
        #expect(StreamSession.presentTripLastClearedAt.isFinite)
        #expect(recorder.idrRequests == 1)
        session.escalatePresentRecovery(dec: decoder, trip: trip(stalled: true), stalledFor: threshold + 1)
        #expect(session.pacingGiveUpCount == 1)
        #expect(recorder.idrRequests == 1)
    }

    /// The second trip inside the sticky window skips the cheap stages.
    @Test func secondTripInTheClusterJumpsToTheGiveUp() {
        let (session, decoder) = makeSession()
        StreamSession.presentTripsInCluster = 2
        defer { StreamSession.presentTripsInCluster = 0 }
        session.escalatePresentRecovery(dec: decoder, trip: trip(stalled: true), stalledFor: 0.3)
        #expect(session.lastPresentRecoveryStage == 3)
        #expect(session.pacingGiveUpCount == 1)
    }

    @Test func linkDeadNeedsTwoSilentEvaluationsWithoutNewTicks() {
        let (session, _) = makeSession()
        let silent = liveness(sinceTick: 0.3, totalTicks: 100)
        #expect(!session.evaluatePresentTrip(live: silent, inStartupGrace: false).linkDead)
        let second = session.evaluatePresentTrip(live: silent, inStartupGrace: false)
        #expect(second.linkDead && second.tripped)
        // A re-priming link advances its tick count, which clears the latch.
        let repriming = liveness(sinceTick: 0.3, totalTicks: 101)
        #expect(!session.evaluatePresentTrip(live: repriming, inStartupGrace: false).linkDead)
        _ = session.evaluatePresentTrip(live: liveness(totalTicks: 101), inStartupGrace: false)
        #expect(!session.evaluatePresentTrip(live: repriming, inStartupGrace: false).linkDead)
    }

    @Test func tickDeficitTripsOnlyWhenReleasesCollapsedToo() {
        let (session, _) = makeSession()
        func deficit(_ live: FramePacer.LivenessSnapshot, grace: Bool = false) -> Bool {
            session.evaluatePresentTrip(live: live, inStartupGrace: grace).tickDeficit
        }
        #expect(deficit(liveness(deficitSeconds: 1.8, releasesPerSecond: 30)))
        #expect(!deficit(liveness(deficitSeconds: 1.8, releasesPerSecond: 110)))
        #expect(!deficit(liveness(deficitSeconds: 1.0, releasesPerSecond: 30)))
        #expect(!deficit(liveness(deficitSeconds: 1.8, releasesPerSecond: 30), grace: true))
        #expect(!deficit(liveness(depth: 0, deficitSeconds: 1.8, releasesPerSecond: 30)))
    }

    @Test func shortRejectStreakClassifiesWithoutTripping() {
        let (session, _) = makeSession()
        let classified = session.evaluatePresentTrip(
            live: liveness(rejectStreak: StreamSession.rendererRejectStreakTrip), inStartupGrace: false)
        #expect(classified.rendererRejecting)
        #expect(!classified.tripped)
        let starved = session.evaluatePresentTrip(
            live: liveness(rejectStreak: 90, sinceLastReject: 0), inStartupGrace: false)
        #expect(starved.rendererStarved && starved.tripped)
    }

    @Test func reenableWaitsForAnUnbrokenHealthyStretch() {
        let (session, decoder) = makeSession()
        session.maybeReenablePacing(dec: decoder, decodeIdle: 0)
        #expect(session.pacingDisabledSince == nil)
        let armed = CFAbsoluteTimeGetCurrent() - 60
        session.pacingDisabledSince = armed
        // Nothing has reached the screen yet, so the window starts over.
        session.maybeReenablePacing(dec: decoder, decodeIdle: 0)
        #expect((session.pacingDisabledSince ?? 0) > armed)
        decoder.statsCollector.recordRendererEnqueue()
        session.pacingDisabledSince = armed
        session.maybeReenablePacing(dec: decoder, decodeIdle: 1)
        #expect((session.pacingDisabledSince ?? 0) > armed)
        // Healthy long enough, but with no view to drive a pacer direct present stays.
        session.pacingDisabledSince = armed
        session.lastPresentRecoveryStage = 3
        session.maybeReenablePacing(dec: decoder, decodeIdle: 0)
        #expect(session.pacingDisabledSince == armed)
        #expect(session.lastPresentRecoveryStage == 3)
    }

    private func liveness(
        sinceTick: Double = 0.004, totalTicks: UInt64 = 5000, depth: Int = 2,
        deficitSeconds: Double = 0, releasesPerSecond: Double = 120,
        rejectStreak: Int = 0, sinceLastReject: Double = .infinity
    ) -> FramePacer.LivenessSnapshot {
        FramePacer.LivenessSnapshot(
            secondsSinceLastTick: sinceTick, secondsSinceLastRelease: 0.004, depth: depth,
            secondsQueueNonEmpty: 0.004, running: true, totalTicks: totalTicks,
            totalReleases: 4000, streamFrameIntervalSeconds: 1.0 / 120, adaptiveTargetDepth: 1,
            recentTicksPerSecond: 120, recentReleasesPerSecond: releasesPerSecond,
            tickDeficitSeconds: deficitSeconds, expectedTickHz: 120, tickDeficitModeActive: false,
            presentRejectStreak: rejectStreak, rendererRefusalSeconds: 0,
            secondsSinceLastReject: sinceLastReject)
    }
}

struct SessionConnectMappingTests {
    private let launch = LaunchResponse(
        sessionURL: "rtsp://192.0.2.1:48010", gcmKey: Data(repeating: 7, count: 16),
        gcmKeyId: Data([1, 2, 3, 4]))
    private let server = ServerInfo(address: "192.0.2.1", uniqueId: "pc", serverName: "Den PC")

    /// An explicit route is honoured without a probe, and re-latched on every build.
    @Test func explicitRouteSetsPacketSizeAndTheDownshiftTier() async {
        let session = StreamSession(backend: InputRecordingBackend())
        var config = StreamConfig(width: 2560, height: 1440, fps: 120, bitrateKbps: 80_000)
        config.remoteness = .remote
        let remote = await session.makeBackendConfig(config: config, launch: launch, server: server)
        #expect(remote.packetSize == Int32(StreamPathMTU.remotePacketSize))
        #expect(remote.streamingRemotely == StreamProtocol.STREAM_CFG_REMOTE)
        #expect(remote.bitrate == 80_000)
        #expect(remote.width == 2560 && remote.height == 1440 && remote.fps == 120)
        #expect(remote.clientRefreshRateX100 == 12_000)
        #expect(remote.remoteInputAesKey == [UInt8](repeating: 7, count: 16))
        #expect(remote.remoteInputAesIv == [1, 2, 3, 4])
        #expect(await session.isRemotePathSession)

        config.remoteness = .local
        let local = await session.makeBackendConfig(config: config, launch: launch, server: server)
        #expect(local.packetSize == 1392)
        #expect(local.streamingRemotely == StreamProtocol.STREAM_CFG_LOCAL)
        #expect(await !session.isRemotePathSession)
    }

    @Test func attemptsStopWhenNotStreamingOrPastTheDeadline() async throws {
        let session = StreamSession(backend: InputRecordingBackend())
        await #expect(throws: CancellationError.self) { try await session.checkAttempt() }
        await session.markStreamingForAttemptTest()
        try await session.checkAttempt(deadline: .distantFuture)
        await #expect {
            try await session.checkAttempt(deadline: .distantPast)
        } throws: { error in
            if case StreamError.hostTimedOut = error { return true }
            return false
        }
    }
}

private extension StreamSession {
    func markStreamingForAttemptTest() { isStreaming = true }
}
