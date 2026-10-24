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
    @Test func touchStaysEnabledWithControllerAndAfterRecovery() async throws {
        let fixture = PlaybackFixture()
        fixture.controllerConnected = true
        let model = fixture.model()
        let controller = StreamViewController(model: model, close: {})
        controller.loadViewIfNeeded()
        model.start(surface: controller.surface)
        model.receive(fixture.update(.firstFrame))
        let touch = try #require(controller.touchCapture)
        #expect(touch.primaryTap.isEnabled && touch.pointerPan.isEnabled)
        model.receive(fixture.update(.input(.controllersActive(true))))
        #expect(touch.primaryTap.isEnabled && touch.pointerPan.isEnabled)
        model.showControls()
        #expect(!touch.primaryTap.isEnabled)
        model.resumeInput()
        #expect(touch.primaryTap.isEnabled)
        model.receive(fixture.update(.reconnecting))
        #expect(!touch.primaryTap.isEnabled)
        model.receive(fixture.update(.reconnected))
        #expect(touch.primaryTap.isEnabled)
        model.stop()
        await model.waitUntilStopped()
        #expect(!touch.primaryTap.isEnabled)
    }

    @Test func connectedControllerStartsCleanAndHotplugRestoresInputWithoutOverridingManualControls() async {
        let fixture = PlaybackFixture()
        fixture.controllerConnected = true
        let model = fixture.model()
        model.start(surface: StreamSurface())
        #expect(!model.inputFocused)
        model.receive(fixture.update(.firstFrame))
        #expect(model.controllerConnected && model.inputFocused && !model.controlsVisible)
        fixture.connectionChanged?(false)
        #expect(!model.inputFocused && model.controlsVisible)
        fixture.connectionChanged?(true)
        #expect(model.inputFocused && !model.controlsVisible)
        model.showControls()
        fixture.connectionChanged?(false)
        fixture.connectionChanged?(true)
        #expect(model.controlsVisible && !model.inputFocused)
        model.resumeInput()
        model.receive(fixture.update(.reconnecting))
        #expect(!model.inputFocused)
        model.receive(fixture.update(.reconnected))
        #expect(model.inputFocused && !model.controlsVisible)
        model.stop()
        await model.waitUntilStopped()
        fixture.connectionChanged?(true)
        #expect(!model.controllerConnected && !model.inputFocused)
    }

    @Test func controllerMouseNoticeFollowsMenuEventsAndNeverReopensTheOverlay() async throws {
        let fixture = PlaybackFixture()
        fixture.controllerConnected = true
        let model = fixture.model()
        model.start(surface: StreamSurface())
        model.receive(fixture.update(.firstFrame))
        let connection = StreamConnection(video: ConnectionTestVideoSink()) { _, _ in }
        let registration = try #require(connection.input.registerController(
            ControllerDescriptor(kind: .unknown, supportedButtons: [], capabilities: [])))
        model.receive(fixture.update(.input(.mouseMode(registration, enabled: true))))
        #expect(model.controllerMouseActive && model.inputFocused && !model.controlsVisible)
        #expect(model.controllerModeMessage == "Mouse mode · Right stick")
        model.receive(fixture.update(.input(.controllersActive(false))))
        #expect(model.controllerMouseActive)
        model.receive(fixture.update(.input(.mouseMode(registration, enabled: false))))
        #expect(!model.controllerMouseActive && model.controllerModeMessage == "Gamepad mode")
        model.stop()
        await model.waitUntilStopped()
        model.receive(fixture.update(.input(.mouseMode(registration, enabled: true))))
        #expect(!model.controllerMouseActive && model.controllerModeMessage == nil)
        await connection.stop()
    }

    @Test func realPreparedPlaybackCanStopBeforeStartWithoutContactingPC() async throws {
        var quiesces = 0
        let scene = try #require(UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.first)
        let window = UIWindow(windowScene: scene)
        let surface = StreamSurface(frame: CGRect(x: 0, y: 0, width: 852, height: 393))
        window.addSubview(surface)
        defer { surface.removeFromSuperview() }
        let playback = try StreamPlayback.make(launch: testLaunch(), surface: surface) { quiesces += 1 }
        let pixels = scene.screen.nativeBounds.size
        #expect(playback.format == StreamFormat(width: Int(max(pixels.width, pixels.height)),
                                                height: Int(min(pixels.width, pixels.height)),
                                                fps: min(120, scene.screen.maximumFramesPerSecond)))
        await playback.stop()
        await playback.stop()
        #expect(quiesces == 1)
        #expect(playback.input?.registerController(
            ControllerDescriptor(kind: .unknown, supportedButtons: [], capabilities: [])) == nil)
        var stopped = 0
        for await update in playback.events {
            #expect(update.sessionID == playback.id)
            if case .stopped = update.event { stopped += 1 }
        }
        #expect(stopped == 1)
        await #expect(throws: CancellationError.self) { try await playback.start() }
    }

    @Test func unavailableDisplayEndsBeforeMediaOrIdleTimerChanges() {
        var writes: [Bool] = []
        let activity = AppDisplayActivity(development: true) { writes.append($0) }
        activity.update(.active, streamActive: false)
        let model = StreamSessionModel(launch: testLaunch())
        model.start(surface: StreamSurface())
        #expect(model.phase.isEnded)
        #expect(model.streamInput == nil && model.requestedFormat == nil)
        #expect(writes == [true])
        model.start(surface: StreamSurface())
        #expect(writes == [true])
    }

    @Test func controlsAndTemporaryInactivityOwnInputFocus() async {
        let fixture = PlaybackFixture()
        let model = fixture.model()
        var focus: [Bool] = []
        model.inputCaptureChanged = { focus.append($0) }
        model.start(surface: StreamSurface())
        model.receive(fixture.update(.firstFrame))
        #expect(model.controlsVisible)
        #expect(!model.inputFocused)
        model.resumeInput()
        #expect(model.inputFocused)
        model.showControls()
        #expect(!model.inputFocused)
        model.resumeInput()
        model.availabilityChanged(active: false, background: false, protectedDataAvailable: true)
        #expect(!model.inputFocused)
        model.resumeInput()
        #expect(!model.inputFocused)
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        #expect(model.inputFocused)
        model.stop()
        await model.waitUntilStopped()
        #expect(focus == [false, true, false, true, false, true, false, false])
    }

    @Test func sceneSuppressionForwardsAvailabilityInputs() async throws {
        let fixture = PlaybackFixture()
        // Without granted background time, leaving disconnects and the return is never forwarded.
        fixture.backgroundCalls = .init(begin: { _ in .init(rawValue: 42) }, end: { _ in },
                                         now: { 0 }, sleep: { throw CancellationError() })
        let model = fixture.model()
        model.start(surface: StreamSurface())
        model.availabilityChanged(active: false, background: true, protectedDataAvailable: true)
        let hidden = try #require(fixture.visibilityInputs.last)
        #expect(hidden.reason == .sceneAvailability && hidden.appActive == false && hidden.background == true)
        #expect(hidden.protectedDataAvailable == true && hidden.returnedInTime == true)
        #expect(fixture.visibility.last == false)
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        #expect(fixture.visibilityInputs.last?.appActive == true && fixture.visibility.last == true)
        model.stop()
        await model.waitUntilStopped()
    }

    @Test func videoHasAccessibleShowControlsAction() {
        let model = PlaybackFixture().model()
        let controller = StreamViewController(model: model, close: {})
        controller.loadViewIfNeeded()
        #expect(controller.surface.accessibilityCustomActions?.map(\.name) == ["Show controls"])
        #expect(controller.controllerUserInteractionEnabled)
    }

    @Test func onlyMatchingFirstFramePromotesStream() async {
        let fixture = PlaybackFixture()
        let model = fixture.model()
        model.start(surface: StreamSurface())
        model.receive(fixture.update(.connectionEstablished))
        #expect(model.phase == .connecting)
        model.receive(.init(sessionID: UUID(), attemptID: UUID(), event: .firstFrame))
        #expect(model.phase == .connecting)
        model.receive(fixture.update(.firstFrame))
        #expect(model.phase == .streaming)
        model.stop()
        await model.waitUntilStopped()
    }

    @Test func shutdownWaitsForTransportAndCannotUndoReactivatedAppKeepAwake() async {
        let fixture = PlaybackFixture()
        var idleDisabled = false
        let activity = AppDisplayActivity(development: true) { idleDisabled = $0 }
        activity.update(.active, streamActive: false)
        let gate = StreamTestGate()
        fixture.stop = { await gate.wait() }
        let model = fixture.model()
        model.start(surface: StreamSurface())
        #expect(idleDisabled)
        model.stop()
        activity.update(.background, streamActive: true)
        #expect(!idleDisabled)
        activity.update(.active, streamActive: true)
        #expect(model.phase == .stopping)
        #expect(fixture.completedStops == 0)
        model.receive(fixture.update(.firstFrame))
        model.start(surface: StreamSurface())
        #expect(model.phase == .stopping)
        #expect(fixture.makes == 1)
        await gate.release()
        await model.waitUntilStopped()
        #expect(fixture.completedStops == 1)
        activity.update(.active, streamActive: false)
        #expect(idleDisabled)
        #expect(model.phase.isEnded)
        model.stop()
        #expect(fixture.completedStops == 1)
    }

    @Test func controllerDisconnectDismissesAfterTeardownWithoutConfirmation() async {
        let fixture = PlaybackFixture()
        let gate = StreamTestGate()
        fixture.stop = { await gate.wait() }
        let model = fixture.model()
        model.start(surface: StreamSurface())
        model.receive(fixture.update(.firstFrame))
        model.receive(fixture.update(.input(.stopRequested)))
        #expect(model.dismissWhenStopped && model.phase == .stopping)
        #expect(!model.inputFocused)
        await gate.release()
        await model.waitUntilStopped()
        #expect(model.phase.isEnded && fixture.completedStops == 1)
    }

    @Test func sessionStatusUsesCanonicalEventsAndLeavesHDRToEngine() async {
        let fixture = PlaybackFixture()
        let model = fixture.model()
        model.start(surface: StreamSurface())
        model.receive(.init(sessionID: UUID(), attemptID: UUID(), event: .audioFailed("old")))
        #expect(!model.audioUnavailable)
        model.receive(fixture.update(.audioFailed("unavailable")))
        model.receive(fixture.update(.connectionStatus(.poor)))
        model.receive(fixture.update(.hdrModeChanged(false)))
        #expect(model.audioUnavailable)
        #expect(model.connectionPoor)
        model.stop()
        model.receive(fixture.update(.connectionStatus(.good)))
        await model.waitUntilStopped()
        #expect(model.connectionPoor)
    }

    @Test func recoveryKeepsPresentationAndReacquiresInputOnlyOnCanonicalLiveEvent() async {
        let fixture = PlaybackFixture()
        let model = fixture.model()
        model.start(surface: StreamSurface())
        model.receive(fixture.update(.firstFrame))
        model.resumeInput()
        #expect(model.inputFocused)
        fixture.quiesce?()
        #expect(!model.inputFocused)
        model.availabilityChanged(active: true, background: false, protectedDataAvailable: true)
        model.resumeInput()
        #expect(!model.inputFocused)
        model.receive(fixture.update(.reconnecting))
        #expect(model.phase == .reconnecting && !model.inputFocused)
        #expect(fixture.completedStops == 0 && fixture.makes == 1)
        model.receive(fixture.update(.connectionEstablished))
        #expect(model.phase == .reconnecting)
        model.receive(fixture.update(.reconnected))
        #expect(model.phase == .streaming && model.inputFocused)
        model.stop()
        await model.waitUntilStopped()
    }

    @Test func canonicalVideoHoldIsInformationalAndDoesNotSuspendInput() async {
        let fixture = PlaybackFixture()
        let model = fixture.model()
        model.start(surface: StreamSurface())
        model.receive(fixture.update(.firstFrame))
        model.resumeInput()
        model.receive(fixture.update(.waitingForVideo(true)))
        #expect(model.waitingForVideo && model.phase == .streaming && model.inputFocused)
        #expect(fixture.completedStops == 0)
        model.receive(fixture.update(.waitingForVideo(false)))
        #expect(!model.waitingForVideo && model.phase == .streaming && model.inputFocused)
        model.stop()
        await model.waitUntilStopped()
    }

    @Test func terminalEventRestoresNativeStateWithoutStartingAnotherStop() {
        let fixture = PlaybackFixture()
        let model = fixture.model()
        model.start(surface: StreamSurface())
        model.receive(fixture.update(.connectionTerminated(errorCode: -1)))
        #expect(model.phase == .stopping)
        model.receive(fixture.update(.stopped))
        #expect(model.phase.isEnded)
        #expect(fixture.completedStops == 0)
        model.stop()
        #expect(fixture.completedStops == 0)
    }

    @Test(arguments: [false, true])
    func blockedPortSurvivesStartFailureEventOrdering(eventsFirst: Bool) async {
        let fixture = PlaybackFixture()
        let model = fixture.model()
        fixture.start = {
            if eventsFirst {
                await MainActor.run {
                    model.receive(fixture.update(.stageFailed(name: "RTSP", errorCode: -1)))
                    model.receive(fixture.update(.stopped))
                }
            }
            throw StreamError.streamPortsBlocked(proto: "TCP", port: 48010)
        }
        model.start(surface: StreamSurface())
        await model.waitUntilStartFinishes()
        if !eventsFirst {
            model.receive(fixture.update(.stageFailed(name: "RTSP", errorCode: -1)))
            model.receive(fixture.update(.stopped))
        }
        #expect(model.phase == .ended("Test PC answered, but the stream couldn't get through. "
            + "Check that the PC's firewall allows TCP 48010."))
    }

    @Test func protectedContentReasonSurvivesStoppedAndLateStartError() async {
        let fixture = PlaybackFixture()
        let model = fixture.model()
        fixture.start = {
            await MainActor.run {
                model.receive(fixture.update(.connectionTerminated(
                    errorCode: Int32(bitPattern: 0x800E_9302))))
                model.receive(fixture.update(.stopped))
            }
            throw StreamError.sessionFailed(-1)
        }
        model.start(surface: StreamSurface())
        await model.waitUntilStartFinishes()
        #expect(model.phase == .ended("Test PC stopped the stream: "
            + "the app is showing protected content, which can't be streamed. Close it on the PC, then try again."))
    }

    @Test func exhaustedReconnectRetainsItsConnectionReason() async {
        let fixture = PlaybackFixture()
        let model = fixture.model()
        model.start(surface: StreamSurface())
        await model.waitUntilStartFinishes()
        model.receive(fixture.update(.firstFrame))
        model.receive(fixture.update(.reconnecting))
        model.receive(fixture.update(.connectionTerminated(errorCode: 0,
            error: .streamPortsBlocked(proto: "TCP", port: 48010))))
        model.receive(fixture.update(.stopped))
        #expect(model.phase == .ended("Test PC answered, but the stream couldn't get through. "
            + "Check that the PC's firewall allows TCP 48010."))
    }

    @Test func pairingFailureUsesIOSRecoveryAndNamesPC() async {
        let fixture = PlaybackFixture()
        fixture.start = { throw StreamConnection.Failure.pairingRequired }
        let model = fixture.model()
        model.start(surface: StreamSurface())
        await model.waitUntilStartFinishes()
        #expect(model.phase == .ended("Couldn't use the saved pairing with Test PC. "
            + "In Settings → PCs, forget the PC and pair again."))
    }

    @Test func cancelledStartDoesNotSuggestConnectionRecovery() async {
        let fixture = PlaybackFixture()
        fixture.start = { throw CancellationError() }
        let model = fixture.model()
        model.start(surface: StreamSurface())
        await model.waitUntilStartFinishes()
        #expect(model.phase == .ended("Disconnected from Test PC."))
    }

    @Test func explicitDisconnectWinsOverLateStartFailure() async {
        let fixture = PlaybackFixture()
        let model = fixture.model()
        fixture.start = {
            await MainActor.run {
                model.receive(fixture.update(.stageFailed(name: "RTSP", errorCode: -1)))
                model.disconnect()
            }
            await model.waitUntilStopped()
            throw StreamError.streamPortsBlocked(proto: "TCP", port: 48010)
        }
        model.start(surface: StreamSurface())
        await model.waitUntilStartFinishes()
        #expect(model.phase == .ended("Disconnected from Test PC."))
    }

    @Test func failedDisplayLayerReplacementRebindsRenderer() {
        let surface = StreamSurface(frame: CGRect(x: 0, y: 0, width: 852, height: 393))
        let failedLayer = surface.displayLayer
        var boundLayer: AVSampleBufferDisplayLayer? = failedLayer
        let replacement = surface.replaceDisplayLayer { boundLayer = $0 }
        #expect(replacement !== failedLayer)
        #expect(boundLayer === replacement)
        #expect(surface.displayLayer === replacement)
        #expect(replacement.superlayer === surface.layer)
        #expect(failedLayer.superlayer == nil)
        #expect(replacement.videoGravity ==
            (surface.traitCollection.userInterfaceIdiom == .pad ? .resizeAspect : .resizeAspectFill))
        #expect(replacement.frame == surface.bounds && surface.clipsToBounds)
    }

    @Test func streamSurfaceFillsVideoAndSupportsBothLandscapeOrientations() {
        let surface = StreamSurface(frame: CGRect(x: 0, y: 0, width: 800, height: 400))
        surface.layoutIfNeeded()
        #expect(surface.displayLayer.frame == surface.bounds)
        #expect(surface.displayLayer.videoGravity ==
            (surface.traitCollection.userInterfaceIdiom == .pad ? .resizeAspect : .resizeAspectFill))
        #expect(surface.clipsToBounds)
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
final class PlaybackFixture {
    let id = UUID()
    var makes = 0
    var visibility: [Bool] = []
    var visibilityInputs: [VideoDecoder.PresentationVisibility] = []
    var focusHistory: [Bool] = []
    var completedStops = 0
    var quiesce: (@MainActor @Sendable () -> Void)?
    var controllerConnected = false
    var connectionChanged: (@MainActor (Bool) -> Void)?
    var backgroundCalls = StreamBackgroundGrace.Calls(begin: { _ in .invalid }, end: { _ in })
    var start: @Sendable () async throws -> Void = {}
    var stop: @Sendable () async -> Void = {}
    let events = AsyncStream<StreamSession.Update>.makeStream()

    func update(_ event: StreamEvent) -> StreamSession.Update {
        .init(sessionID: id, attemptID: UUID(), event: event)
    }

    func model() -> StreamSessionModel {
        StreamSessionModel(launch: testLaunch(), backgroundGrace: StreamBackgroundGrace(calls: backgroundCalls),
                           makePlayback: { [self] _, _, quiesce in
            makes += 1
            self.quiesce = quiesce
            return StreamPlayback(id: id, events: events.stream, start: start, stop: { [self] in
                await stop()
                await MainActor.run { completedStops += 1 }
            }, screenChanged: {}, focusInput: { [self] in focusHistory.append($0) },
               setVisible: { [self] visible, inputs in
                   visibility.append(visible)
                   visibilityInputs.append(inputs)
               },
               observeControllers: { [self] changed in
                connectionChanged = changed
                changed(controllerConnected)
            })
        })
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
