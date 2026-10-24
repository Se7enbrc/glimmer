// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

@testable import GlimmerEngine
@testable import Glimmer
import AVFAudio
import AudioToolbox
import Foundation
import Testing

struct AudioBoundaryTests {
    private let settings = IsolatedDefaults()

    @Test func sharedOutputRetainsTheMacAdapterUntilItsLastOwnerReleasesIt() throws {
        var adapter: AudioHALOutput? = AudioHALOutput(channels: 2)
        weak let observedAdapter = adapter
        let storage = try #require(adapter?.storage)
        var output = adapter?.sharedOutput
        storage.queue.pointee.enabled.store(true, ordering: .releasing)
        adapter = nil
        #expect(observedAdapter != nil)
        #expect(output?.queue == storage.queue)
        output = nil
        #expect(observedAdapter == nil)
        #expect(Bool(!storage.queue.pointee.enabled.load(ordering: .acquiring)))
    }

    @Test func failedDisposalPermanentlyRetainsTheCallbackStorage() throws {
        var storage: AudioRenderStorage? = AudioRenderStorage(channels: 2)
        let queue = try #require(storage?.queue)
        var attempts = 0
        storage?.dispose { attempts += 1; return false }
        storage?.dispose { attempts += 1; return true }
        storage = nil
        #expect(attempts == 2)
        // No real unit owns this test pointer; reclaim the intentionally retained storage after inspection.
        #expect(queue.pointee.channels == 2)
        #expect(Bool(!queue.pointee.enabled.load(ordering: .acquiring)))
        queue.deinitialize(count: 1)
        queue.deallocate()
    }

    @Test func adapterFailureKeepsReceptionAliveAndArmsRecovery() {
        let fixture = Fixture()
        fixture.failure = kAudioUnitErr_Uninitialized
        let decoder = AudioDecoder(platform: fixture.platform(), defaults: settings.defaults)
        defer { decoder.shutdown() }
        #expect(decoder.initialize(audioConfig: AudioConfig.stereo.cValue, opus: Self.opus) == 0)
        #expect(!decoder.engineRunning)
        #expect(decoder.engineRestartRetries == 1)
        #expect(decoder.outputGraphNeedsReconnect)
        fixture.failure = nil
        decoder.retryEngineStart(attempt: 1, generation: decoder.engineRestartGeneration)
        #expect(decoder.engineRunning)
        #expect(decoder.engineRestartRetries == 0)
    }

    @Test func queuedDeviceChangeCannotRestartAfterShutdownOrReinitialization() throws {
        let fixture = Fixture()
        let decoder = AudioDecoder(platform: fixture.platform(), defaults: settings.defaults)
        defer { decoder.shutdown() }
        #expect(decoder.initialize(audioConfig: AudioConfig.stereo.cValue, opus: Self.opus) == 0)
        let oldChange = try #require(fixture.deviceChanged)
        let oldRoute = try #require(fixture.routeChanged)
        decoder.shutdown()
        let count = fixture.starts
        oldChange(123)
        oldRoute(123)
        #expect(fixture.starts == count)
        #expect(decoder.isShutdown)
        #expect(decoder.initialize(audioConfig: AudioConfig.stereo.cValue, opus: Self.opus) == 0)
        let restarted = fixture.starts
        oldChange(456)
        oldRoute(456)
        #expect(fixture.starts == restarted)
        #expect(decoder.deviceRecoveryStarted == 0)
        fixture.deviceChanged?(789)
        #expect(fixture.starts == restarted + 1)
        #expect(decoder.deviceRecoveryStarted == 789)
    }

    @Test(arguments: [false, true])
    func queuedRateCannotReachAReplacementOutput(reinitialize: Bool) {
        let fixture = Fixture()
        let decoder = AudioDecoder(platform: fixture.platform(), defaults: settings.defaults)
        defer { decoder.shutdown() }
        #expect(decoder.initialize(audioConfig: AudioConfig.stereo.cValue, opus: Self.opus) == 0)
        decoder.routeListenerQueue.suspend()
        decoder.applyVarispeedRate(1.001)
        if reinitialize {
            decoder.shutdown()
            #expect(decoder.initialize(audioConfig: AudioConfig.stereo.cValue, opus: Self.opus) == 0)
        } else {
            decoder.handleEngineConfigurationChange()
        }
        decoder.routeListenerQueue.resume()
        decoder.routeListenerQueue.sync {}
        #expect(fixture.appliedRates.isEmpty)
        decoder.applyVarispeedRate(1.0002)
        decoder.routeListenerQueue.sync {}
        #expect(fixture.appliedRates == [1.0002])
    }

    @Test func shutdownWaitsForAnInFlightRouteChangeAndDisposesReplacement() async throws {
        let fixture = Fixture()
        let decoder = AudioDecoder(platform: fixture.platform(), defaults: settings.defaults)
        #expect(decoder.initialize(audioConfig: AudioConfig.stereo.cValue, opus: Self.opus) == 0)
        let entered = DispatchSemaphore(value: 0)
        let release = DispatchSemaphore(value: 0)
        let changed = DispatchSemaphore(value: 0)
        let stopped = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            decoder.handleEngineConfigurationChange(changedAt: 123) {
                entered.signal()
                release.wait()
            }
            changed.signal()
        }
        #expect(await entered.waitAsync(for: .seconds(2)) == .success)
        DispatchQueue.global().async {
            decoder.shutdown()
            stopped.signal()
        }
        #expect(await stopped.waitAsync(for: .milliseconds(50)) == .timedOut)
        release.signal()
        #expect(await changed.waitAsync(for: .seconds(2)) == .success)
        #expect(await stopped.waitAsync(for: .seconds(2)) == .success)
        #expect(decoder.halOutput == nil)
        #expect(decoder.meterShutdown && !decoder.engineRunning)
        #expect(fixture.routeRemoved > 0 && fixture.devicesRemoved > 0)
        #expect(fixture.starts == 2)
        #expect(fixture.disposals == 2)
    }

    @Test func deviceListenerDeliversTheCapturedGenerationOnTheOwnedQueue() throws {
        let adapter = MacAudio()
        let called = DispatchSemaphore(value: 0)
        adapter.configurationChanged = { timestamp in
            #expect(timestamp > 0)
            called.signal()
        }
        var callback: (@Sendable () -> Void)?
        adapter.installDeviceListeners(defaultDevice: { 42 }, streams: { _ in [] }, add: { _, _, handler in
            callback = handler
            return (1, noErr)
        })
        adapter.removeDeviceListeners { _, _, _ in noErr }
        adapter.configurationChanged = { _ in Issue.record("Old listeners must not acquire a new session callback") }
        let notify = try #require(callback)
        notify()
        adapter.routeListenerQueue.sync {}
        #expect(called.wait(timeout: .now()) == .success)
    }

    private static let opus = OpusConfig(sampleRate: 48_000, channelCount: 2, streams: 1,
                                          coupledStreams: 1, samplesPerFrame: 240, mapping: [0, 1])

    // The lock protects test observations independently of the decoder’s graph and maintenance queues.
    private final class Fixture: @unchecked Sendable {
        private let lock = NSLock()
        private var status: OSStatus?
        private var startCount = 0
        private var removedRoutes = 0
        private var removedDevices = 0
        private var disposalCount = 0
        private var rates: [Float] = []
        private var change: (@Sendable (UInt64) -> Void)?
        private var route: (@Sendable (UInt64) -> Void)?
        var failure: OSStatus? {
            get { lock.withLock { status } }
            set { lock.withLock { status = newValue } }
        }
        var starts: Int { lock.withLock { startCount } }
        var routeRemoved: Int { lock.withLock { removedRoutes } }
        var devicesRemoved: Int { lock.withLock { removedDevices } }
        var disposals: Int { lock.withLock { disposalCount } }
        var appliedRates: [Float] { lock.withLock { rates } }
        var deviceChanged: (@Sendable (UInt64) -> Void)? { lock.withLock { change } }
        var routeChanged: (@Sendable (UInt64) -> Void)? { lock.withLock { route } }

        func platform() -> AudioPlatform {
            AudioPlatform(makeOutput: { format in
                if let failure = self.failure { throw AudioOutput.Failure(status: failure) }
                let adapter = OutputAdapter(channels: Int(format.channelCount),
                    started: { self.lock.withLock { self.startCount += 1 } },
                    disposed: { self.lock.withLock { self.disposalCount += 1 } })
                return AudioOutput(storage: adapter.storage, sampleRate: format.sampleRate,
                    channels: format.channelCount, latencyMs: 0, start: { adapter.start(); return noErr },
                    isRunning: { true }, setRate: { rate in
                        self.lock.withLock { self.rates.append(rate) }
                        return noErr
                    }, lastRenderError: { noErr })
            }, sampleRoute: { AudioRoute(label: "test", uid: nil) },
            installRouteListener: { _, _, changed in self.lock.withLock { self.route = changed } },
            removeRouteListener: { _ in self.lock.withLock { self.removedRoutes += 1 } },
            installDeviceListeners: { _, changed in self.lock.withLock { self.change = changed } },
            removeDeviceListeners: { self.lock.withLock { self.removedDevices += 1 } },
            captureVolume: { { AudioOutputVolume(volume: nil, muted: nil, routeChanged: false) } },
            environment: { AudioEnvironment(host: "unknown", link: "unknown", jitterMs: 0) })
        }
    }

    private final class OutputAdapter {
        let storage: AudioRenderStorage
        private let started: () -> Void
        private let disposed: () -> Void

        init(channels: Int, started: @escaping () -> Void, disposed: @escaping () -> Void) {
            storage = AudioRenderStorage(channels: channels)
            self.started = started
            self.disposed = disposed
        }

        func start() { started() }

        deinit {
            storage.dispose { disposed(); return true }
        }
    }
}

extension AudioHALOutput {
    var queue: UnsafeMutablePointer<AudioPCMQueue> { storage.queue }
}
