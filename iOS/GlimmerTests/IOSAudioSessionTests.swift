// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AVFAudio
import GlimmerEngine
import Testing
@testable import Glimmer

struct IOSAudioSessionTests {
    @Test func actualRouteAndLastGraphControlDeactivation() throws {
        let fixture = AudioSessionFixture()
        let session = fixture.makeSession()
        fixture.observe(session)
        let first = try session.acquire(sampleRate: 48_000)
        #expect(first.route.sampleRate == 44_100)
        #expect(first.route.bufferDuration == 0.01)
        _ = try session.acquire(sampleRate: 48_000)
        #expect(fixture.read { $0.calls } == ["configure:48000", "activate"])
        fixture.close(session)
        session.release()
        #expect(!fixture.read { $0.calls.contains("deactivate") })
        session.release()
        #expect(fixture.read { $0.calls.last } == "deactivate")
    }

    @Test func rebuildKeepsSessionActiveAndShutdownRemovesObservers() throws {
        let fixture = AudioSessionFixture()
        let session = fixture.makeSession()
        fixture.observe(session)
        _ = try session.acquire(sampleRate: 48_000)
        session.removeDeviceListeners()
        session.release()
        #expect(!fixture.read { $0.calls.contains("deactivate") })
        _ = try session.acquire(sampleRate: 48_000)
        fixture.close(session)
        session.release()
        fixture.post(AVAudioSession.routeChangeNotification, to: session)
        #expect(!fixture.read { $0.calls.contains("route") || $0.calls.contains("device") })
    }

    @Test func activationFailureCanRetryAndInvalidRouteReleasesSession() throws {
        let fixture = AudioSessionFixture()
        let session = fixture.makeSession()
        fixture.observe(session)
        fixture.read { $0.activationFails = true }
        #expect(throws: AudioOutput.Failure.self) { try session.acquire(sampleRate: 48_000) }
        fixture.read { $0.activationFails = false }
        _ = try session.acquire(sampleRate: 48_000)
        session.release()
        fixture.read {
            $0.route = IOSAudioSession.Route(label: "", uid: nil, sampleRate: 0, channels: 0,
                                            latency: 0, bufferDuration: 0, volume: 0)
        }
        #expect(throws: AudioOutput.Failure.self) { try session.acquire(sampleRate: 48_000) }
        #expect(fixture.read { $0.calls.last } == "deactivate")
        fixture.close(session)
    }

    @Test func interruptionBlocksPlaybackUntilResumePermissionAndInvalidatesOldGraph() throws {
        let fixture = AudioSessionFixture()
        let session = fixture.makeSession()
        fixture.observe(session)
        let original = try session.acquire(sampleRate: 48_000)
        fixture.post(AVAudioSession.interruptionNotification, to: session,
                     info: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.began.rawValue])
        #expect(!session.withPlayback(generation: original.generation, unavailable: false) { true })
        #expect(throws: AudioOutput.Failure.self) { try session.acquire(sampleRate: 48_000) }
        fixture.post(AVAudioSession.interruptionNotification, to: session,
                     info: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue])
        #expect(throws: AudioOutput.Failure.self) { try session.acquire(sampleRate: 48_000) }
        fixture.post(AVAudioSession.interruptionNotification, to: session,
                     info: [AVAudioSessionInterruptionTypeKey: AVAudioSession.InterruptionType.ended.rawValue,
                            AVAudioSessionInterruptionOptionKey:
                                AVAudioSession.InterruptionOptions.shouldResume.rawValue])
        let resumed = try session.acquire(sampleRate: 48_000)
        #expect(resumed.generation != original.generation)
        #expect(session.withPlayback(generation: resumed.generation, unavailable: false) { true })
        #expect(!session.withPlayback(generation: original.generation, unavailable: false) { true })
        fixture.close(session)
        session.release()
        session.release()
    }

    @Test func mediaServicesResetReconfiguresSessionAndCannotReuseOldGraph() throws {
        let fixture = AudioSessionFixture()
        let session = fixture.makeSession()
        fixture.observe(session)
        let old = try session.acquire(sampleRate: 48_000)
        fixture.post(AVAudioSession.mediaServicesWereLostNotification, to: session)
        #expect(throws: AudioOutput.Failure.self) { try session.acquire(sampleRate: 48_000) }
        fixture.post(AVAudioSession.mediaServicesWereResetNotification, to: session)
        let fresh = try session.acquire(sampleRate: 48_000)
        #expect(fresh.generation != old.generation)
        #expect(fixture.read { $0.calls.filter { $0 == "configure:48000" }.count } == 2)
        #expect(fixture.read { $0.calls.filter { $0 == "device" }.count } == 2)
        fixture.close(session)
        session.release()
        session.release()
    }

    @Test func newStreamCannotRestartAnOldGraphLease() throws {
        let fixture = AudioSessionFixture()
        let session = fixture.makeSession()
        fixture.observe(session)
        let old = try session.acquire(sampleRate: 48_000)
        fixture.close(session)
        fixture.observe(session)
        let fresh = try session.acquire(sampleRate: 48_000)
        #expect(fresh.generation != old.generation)
        #expect(!session.withPlayback(generation: old.generation, unavailable: false) { true })
        #expect(session.withPlayback(generation: fresh.generation, unavailable: false) { true })
        fixture.close(session)
        session.release()
        session.release()
    }

    @Test func volumeSampleRejectsDifferentRoute() {
        let fixture = AudioSessionFixture()
        let session = fixture.makeSession()
        let sample = session.captureVolume()
        #expect(sample().volume == 0.5)
        #expect(sample().muted == nil)
        fixture.read {
            $0.route = IOSAudioSession.Route(label: "New output", uid: "other", sampleRate: 48_000,
                                            channels: 2, latency: 0.1, bufferDuration: 0.01, volume: 1)
        }
        #expect(sample().routeChanged)
        #expect(sample().volume == nil)
    }

    @Test func missingRouteHasNoVolumeMeasurement() {
        let fixture = AudioSessionFixture()
        fixture.read {
            $0.route = IOSAudioSession.Route(label: "", uid: nil, sampleRate: 0, channels: 0,
                                            latency: 0, bufferDuration: 0, volume: 0)
        }
        let session = fixture.makeSession()
        #expect(session.captureVolume()().volume == nil)
        #expect(session.sampleRoute().uid == nil)
    }

    @Test func queuedNotificationFromRemovedObserverCannotReachNewSession() {
        let fixture = AudioSessionFixture()
        let session = fixture.makeSession()
        fixture.observe(session)
        session.events.suspend()
        fixture.center.post(name: AVAudioSession.routeChangeNotification, object: nil)
        fixture.close(session)
        fixture.observe(session)
        session.events.resume()
        session.events.sync {}
        fixture.queue.sync {}
        #expect(fixture.read { $0.calls.isEmpty })
        fixture.post(AVAudioSession.routeChangeNotification, to: session)
        #expect(fixture.read { $0.calls } == ["route"])
        fixture.close(session)
    }
}
