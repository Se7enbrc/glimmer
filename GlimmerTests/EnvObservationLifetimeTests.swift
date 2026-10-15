// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

@testable import GlimmerEngine
import Foundation
import Testing
import os

struct EnvObservationLifetimeTests {
    @Test func failedPreparationAndRepeatedStopReleaseProbesExactlyOnce() {
        let stops = OSAllocatedUnfairLock(initialState: 0)
        do {
            let source = EnvObservationSource(route: { nil }, wifi: { nil }, stop: { stops.withLock { $0 += 1 } })
            source.stop()
            source.stop()
        }
        #expect(stops.withLock { $0 } == 1)
        do {
            let source = EnvObservationSource(route: { nil }, wifi: { nil }, stop: { stops.withLock { $0 += 1 } })
            #expect(source.route() == nil)
        }
        #expect(stops.withLock { $0 } == 2)
    }

    @Test func missingNativeObservationsStillFeedEngineEvidence() async {
        let controller = EnvSignalController()
        controller.beginSession()
        controller.observeStreamTick()
        await drain(controller)
        #expect(controller.lastFedNanos > 0)
        #expect(controller.streamLink == "unknown")
        #expect(controller.rssiSampleCount == 0)
        #expect(controller.txSampleCount == 0)
        #expect(controller.routeSnapshot == nil)
        #expect(controller.steadyPingInterval() == EnvSignalController.fastPingIntervalSeconds)
        controller.endSession()
        #expect(controller.decision.generation == 0)
    }

    @Test func lateNativeSampleCannotPublishAfterStop() async {
        let controller = EnvSignalController()
        let probe = BlockingProbe()
        controller.beginSession(observations: probe.source)
        controller.observeStreamTick()
        for await _ in probe.started { break }
        controller.endSession()
        controller.endSession()
        probe.release.signal()
        await drain(controller)
        #expect(probe.stops.withLock { $0 } == 1)
        #expect(controller.lastFedNanos == 0)
        #expect(controller.rssiSampleCount == 0)
        #expect(controller.streamLink == "unknown")
        #expect(controller.decision.generation == 0)
    }

    @Test func replacementOwnsEvidenceAndEachNativeSourceStopsOnce() async {
        let controller = EnvSignalController()
        let old = BlockingProbe()
        let newStops = OSAllocatedUnfairLock(initialState: 0)
        controller.beginSession(observations: old.source)
        controller.observeStreamTick()
        for await _ in old.started { break }
        let retiredStayedEmpty = OSAllocatedUnfairLock(initialState: false)
        controller.feedQueue.async {
            retiredStayedEmpty.withLock { $0 = controller.rssiSampleCount == 0 && controller.lastFedNanos == 0 }
        }
        controller.beginSession(observations: EnvObservationSource(
            route: { StreamRouteSnapshot(linkLabel: "wired") }, wifi: { nil }, stop: {
                #expect(controller.routeSnapshot == nil)
                newStops.withLock { $0 += 1 }
            }))
        controller.observeStreamTick()
        old.release.signal()
        await drain(controller)
        #expect(retiredStayedEmpty.withLock { $0 })
        #expect(old.stops.withLock { $0 } == 1)
        #expect(controller.streamLink == "wired")
        #expect(controller.rssiSampleCount == 0)
        #expect(controller.routeSnapshot?.linkLabel == "wired")
        controller.endSession()
        controller.endSession()
        #expect(newStops.withLock { $0 } == 1)
        #expect(controller.decision.generation == 0)
    }

    private func drain(_ controller: EnvSignalController) async {
        await withCheckedContinuation { continuation in
            controller.feedQueue.async { continuation.resume() }
        }
    }

    // Immutable synchronization objects own mutable state; the sample blocks only its utility queue.
    private final class BlockingProbe: Sendable {
        let release = DispatchSemaphore(value: 0)
        let stops = OSAllocatedUnfairLock(initialState: 0)
        let started: AsyncStream<Void>
        let entered: AsyncStream<Void>.Continuation

        init() { (started, entered) = AsyncStream.makeStream() }

        var source: EnvObservationSource {
            EnvObservationSource(route: { StreamRouteSnapshot(linkLabel: "wifi") }, wifi: { [self] in
                entered.yield(())
                release.wait()
                return WiFiSnapshot(linkState: .associated, rssiDbm: -40, txRateMbps: 800)
            }, stop: { [self] in stops.withLock { $0 += 1 } })
        }
    }
}
