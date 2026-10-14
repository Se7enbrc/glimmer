// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AVFoundation
import GlimmerEngine
import Testing
import UIKit
@testable import Glimmer

@Suite(.serialized)
@MainActor
struct StreamSessionTests {
    @Test func onlyMatchingFirstFramePromotesStream() async {
        let fixture = PlaybackFixture()
        let model = fixture.model()
        model.start(surface: StreamSurface())
        model.receive(.connection(fixture.id, .connected))
        #expect(model.phase == .connecting)
        model.receive(.firstFrame(UUID()))
        #expect(model.phase == .connecting)
        model.receive(.firstFrame(fixture.id))
        #expect(model.phase == .streaming)
        model.stop()
        await model.waitUntilStopped()
    }

    @Test func shutdownWaitsForTransportAndRestoresIdleTimer() async {
        let fixture = PlaybackFixture()
        let gate = StreamTestGate()
        fixture.stop = { await gate.wait() }
        let model = fixture.model()
        model.start(surface: StreamSurface())
        #expect(fixture.idle)
        model.stop()
        #expect(!fixture.idle)
        #expect(model.phase == .stopping)
        #expect(fixture.teardowns == 0)
        model.receive(.firstFrame(fixture.id))
        model.start(surface: StreamSurface())
        #expect(model.phase == .stopping)
        #expect(fixture.makes == 1)
        await gate.release()
        await model.waitUntilStopped()
        #expect(fixture.teardowns == 1)
        #expect(model.phase.isEnded)
        model.stop()
        #expect(fixture.teardowns == 1)
    }

    @Test func lockBeforeAttachmentPreventsDelayedConnection() {
        let fixture = PlaybackFixture()
        let model = fixture.model()
        model.availabilityChanged(active: false, background: false, protectedDataAvailable: false)
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.start(surface: StreamSurface())
        #expect(fixture.makes == 0)
        #expect(model.phase.isEnded)
    }

    @Test func inactivePreservesStreamButBackgroundStopsWithoutReconnect() async {
        let fixture = PlaybackFixture()
        fixture.idle = true
        let model = fixture.model()
        model.start(surface: StreamSurface())
        model.availabilityChanged(active: false, background: false, protectedDataAvailable: true)
        #expect(model.phase == .connecting)
        model.availabilityChanged(active: false, background: true, protectedDataAvailable: true)
        await model.waitUntilStopped()
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.start(surface: StreamSurface())
        #expect(model.phase.isEnded)
        #expect(fixture.makes == 1)
        #expect(fixture.idle)
    }

    @Test func sessionStatusAndHDRUseOnlyCurrentConnection() async {
        let fixture = PlaybackFixture()
        let model = fixture.model()
        model.start(surface: StreamSurface())
        model.receive(.connection(UUID(), .audioFailed("old")))
        #expect(!model.audioUnavailable)
        model.receive(.connection(fixture.id, .audioFailed("unavailable")))
        model.receive(.connection(fixture.id, .connectionPoor(true)))
        model.receive(.connection(fixture.id, .hdrMode(false)))
        #expect(model.audioUnavailable)
        #expect(model.connectionPoor)
        #expect(fixture.hdr == [false])
        model.stop()
        model.receive(.connection(fixture.id, .hdrMode(true)))
        await model.waitUntilStopped()
        #expect(fixture.hdr == [false])
    }

    @Test func failedDisplayLayerReplacementRebindsRenderer() {
        let surface = StreamSurface()
        let failedLayer = surface.displayLayer
        var boundLayer: AVSampleBufferDisplayLayer? = failedLayer
        let replacement = surface.replaceDisplayLayer { boundLayer = $0 }
        #expect(replacement !== failedLayer)
        #expect(boundLayer === replacement)
        #expect(surface.displayLayer === replacement)
        #expect(replacement.superlayer === surface.layer)
        #expect(failedLayer.superlayer == nil)
    }

    @Test func streamSurfaceFitsVideoAndSupportsBothLandscapeOrientations() {
        let surface = StreamSurface(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        surface.layoutIfNeeded()
        #expect(surface.displayLayer.frame == surface.bounds)
        #expect(surface.displayLayer.videoGravity == .resizeAspect)
        let model = PlaybackFixture().model()
        let controller = StreamViewController(model: model, close: {})
        #expect(controller.supportedInterfaceOrientations == .landscape)
        #expect(controller.prefersStatusBarHidden)
        #expect(controller.prefersHomeIndicatorAutoHidden)
        controller.startWhenReady()
        #expect(model.phase == .idle)
    }
}

@MainActor
private final class PlaybackFixture {
    let id = UUID()
    var idle = false
    var makes = 0
    var teardowns = 0
    var hdr: [Bool] = []
    var connect: @Sendable () async throws -> Void = {}
    var stop: @Sendable () async -> Void = {}

    func model() -> StreamSessionModel {
        StreamSessionModel(launch: testLaunch(), makePlayback: { [self] _, _, _ in
            makes += 1
            return StreamPlayback(id: id, connect: connect, stop: stop, teardown: { self.teardowns += 1 },
                                  screenChanged: {}, setHDR: { self.hdr.append($0) })
        }, readIdleTimer: { self.idle }, writeIdleTimer: { self.idle = $0 })
    }
}

actor StreamTestGate {
    private var released = false
    private var entered = false
    private var enteredWaiters: [CheckedContinuation<Void, Never>] = []
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        entered = true
        for waiter in enteredWaiters { waiter.resume() }
        enteredWaiters = []
        if released { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func waitUntilEntered() async {
        if entered { return }
        await withCheckedContinuation { enteredWaiters.append($0) }
    }
    func release() {
        released = true
        for waiter in waiters { waiter.resume() }
        waiters = []
    }
}

@MainActor
func testLaunch() -> StreamLaunch {
    let server = ServerInfo(address: "pc.invalid", uniqueId: "test-pc", serverName: "Test PC")
    let identity = IdentityManager(defaultsSuite: "io.ugfugl.Glimmer.tests.unused",
                                   supportBase: URL(fileURLWithPath: "/unused"), protectedDataAvailable: { false })
    return StreamLaunch(network: NetworkClient(server: server, identity: identity, deviceName: "Test device"),
                        pcID: server.uniqueId, pcName: server.serverName, appID: 1, appName: "Test game")
}
