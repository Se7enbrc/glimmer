//
//  AudioResamplerHoldTests.swift
//
//  The drift resampler's integral learns only clock skew: it holds through
//  re-primes and cushion target moves, can't wind toward slower playout while
//  trims fire, persists a window mean, and remembers skew per output device.
//

import Foundation
import Testing
@testable import Glimmer

struct AudioResamplerHoldTests {

    /// An engaged loop with no recent event: re-prime long ago, setpoint settled
    /// at `targetMs`, no trim, and the 4Hz rate limit open.
    private func steadyDecoder(targetMs: Double = 100, integralPpm: Double = 0) -> AudioDecoder {
        let decoder = AudioDecoder()
        decoder.audioMeterLock.lock()
        decoder.resamplerIntegralPpm = integralPpm
        decoder.resamplerSetpointMs = targetMs
        decoder.audioMeterLock.unlock()
        return decoder
    }

    @Test func quietTickIntegratesTheFillError() {
        let decoder = steadyDecoder()
        decoder.driveResampler(fillMs: 90, targetMs: 100, engaged: true)
        #expect(decoder.resamplerIntegralPpm == -10 * AudioDecoder.resamplerKiPpmPerMs)
    }

    /// The cushion grew 10ms: fill now reads 10ms short, but that's a setpoint
    /// move, not skew.
    @Test func setpointMoveHoldsTheIntegral() {
        let decoder = steadyDecoder(targetMs: 100, integralPpm: -40)
        decoder.driveResampler(fillMs: 100, targetMs: 110, engaged: true)
        #expect(decoder.resamplerIntegralPpm == -40)
    }

    @Test func rePrimeHoldsTheIntegral() {
        let decoder = steadyDecoder(integralPpm: -40)
        decoder.driftAnchorNanos = DispatchTime.now().uptimeNanoseconds
        decoder.driveResampler(fillMs: 60, targetMs: 100, engaged: true)
        #expect(decoder.resamplerIntegralPpm == -40)
    }

    /// The measured wind-up: the integral ran to the rail while trims fired. A
    /// gap dip after a trim must not push it lower; fill above target still unwinds it.
    @Test func trimHoldBlocksSlowdownButLetsTheIntegralUnwind() {
        let control = steadyDecoder(integralPpm: -200)
        control.driveResampler(fillMs: 60, targetMs: 100, engaged: true)
        #expect(control.resamplerIntegralPpm < -200)

        let decoder = steadyDecoder(integralPpm: -200)
        decoder.lastTrimNanos = DispatchTime.now().uptimeNanoseconds
        decoder.driveResampler(fillMs: 60, targetMs: 100, engaged: true)
        #expect(decoder.resamplerIntegralPpm == -200)
        decoder.lastResamplerUpdateNanos = 0
        decoder.driveResampler(fillMs: 110, targetMs: 100, engaged: true)
        #expect(decoder.resamplerIntegralPpm > -200)
    }

    /// A save window persists the MEAN of its quiet ticks, not the integral's
    /// value at the moment the window closes.
    @Test func savesTheWindowMeanNotTheSnapshot() {
        let key = AudioDecoder.resamplerSkewKey(host: "test-pc", deviceUID: "test-\(UUID().uuidString)")
        defer { UserDefaults.standard.removeObject(forKey: key) }
        let decoder = steadyDecoder(integralPpm: -450)
        decoder.audioMeterLock.lock()
        decoder.resamplerSkewMemoryKey = key
        decoder.resamplerQuietIntegralSumPpm = -100 * 199
        decoder.resamplerQuietTicks = 199
        decoder.audioMeterLock.unlock()
        decoder.driveResampler(fillMs: 100, targetMs: 100, engaged: true)
        let expectedMean = (-100 * 199 - 450) / 200.0
        #expect(abs(AudioDecoder.loadResamplerSkewSeed(key: key) - expectedMean) < 0.1)
    }

    @Test func skewMemoryIsPerOutputDevice() throws {
        let suite = "io.ugfugl.Glimmer.tests.\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let speakers = AudioDecoder.resamplerSkewKey(host: "pc", deviceUID: "speakers")
        let dac = AudioDecoder.resamplerSkewKey(host: "pc", deviceUID: "usb-dac")
        AudioDecoder.persistResamplerSkew(key: speakers, ppm: -120, defaults: defaults)
        #expect(abs(AudioDecoder.loadResamplerSkewSeed(key: speakers, defaults: defaults) + 120) < 0.1)
        #expect(AudioDecoder.loadResamplerSkewSeed(key: dac, defaults: defaults) == 0)
        // A host-only record from before device keying is never read.
        defaults.set(["ppm": -439.0, "saved_at": Date().timeIntervalSinceReferenceDate],
                     forKey: AudioDecoder.resamplerSkewKeyPrefix + "pc")
        #expect(AudioDecoder.loadResamplerSkewSeed(key: dac, defaults: defaults) == 0)
        #expect(AudioDecoder.resamplerSkewKey(host: "pc", deviceUID: nil).isEmpty)
    }

    /// Switching output devices mid-session blends two clocks into the integral,
    /// so nothing more is saved this session; a same-device notification is a no-op.
    @Test func outputDeviceChangeStopsSavingForTheSession() {
        let speakers = AudioDecoder.resamplerSkewKey(host: "pc", deviceUID: "speakers")
        let decoder = AudioDecoder()
        decoder.audioMeterLock.lock()
        decoder.cushionHostLabel = "pc"
        decoder.resamplerSkewMemoryKey = speakers
        decoder.noteOutputDeviceLocked(uid: "speakers")
        let sameDevice = decoder.resamplerSkewMemoryKey
        decoder.noteOutputDeviceLocked(uid: "headphones")
        let afterSwitch = decoder.resamplerSkewMemoryKey
        decoder.audioMeterLock.unlock()
        #expect(sameDevice == speakers)
        #expect(afterSwitch.isEmpty)
    }

    /// A source and output both running 200ppm slow retain constant fill after
    /// 400 seconds, despite 80ms of wall-clock offset. The integral and trough
    /// guards must still hold an unstable or nearly empty cushion.
    @Test(arguments: [(-200.0, 105.0, true), (-501.0, 105.0, false), (-200.0, 5.0, false)])
    func compensatedClockReleasesOnlyAHealthyCushion(ppm: Double, minimumFillMs: Double, releases: Bool) {
        let decoder = steadyDecoder(targetMs: 110, integralPpm: ppm)
        let now = DispatchTime.now().uptimeNanoseconds
        decoder.meterSampleRate = 48_000
        decoder.playoutStarted = true
        decoder.primed = true
        decoder.cushionLinkResolved = true
        decoder.cushionLinkClass = "wired"
        decoder.driftAnchorNanos = now - 400_000_000_000
        decoder.framesScheduled = UInt64(400 * (1 + ppm * 1e-6) * 48_000)
        decoder.framesPlayed = decoder.framesScheduled - 5_280
        decoder.resamplerEpsPpm = ppm
        decoder.lastResamplerUpdateNanos = now
        decoder.playoutTargetMs = 110
        decoder.learnedFloorMs = 105
        decoder.quietWindowMinFillMs = minimumFillMs
        decoder.quietSinceNanos = now - AudioDecoder.playoutDecayQuietNanos
        decoder.floorQuietSinceNanos = now
        decoder.publishAudioState()
        decoder.audioMeterLock.lock()
        defer { decoder.audioMeterLock.unlock() }
        #expect((decoder.cushionQuietAdjustLocked(now: now) != nil) == releases)
        #expect(decoder.playoutTargetMs == (releases ? 100 : 110))
    }

    @Test func correctedClockStaysStableAcrossLongSessions() {
        var window = AudioDecoder.ResamplerDriftWindow()
        for second in 0...3_600 {
            let stable = window.observe(driftMs: Double(second) * 0.2, now: UInt64(second) * 1_000_000_000)
            #expect(stable)
        }
    }

    @Test func driftExcursionNeedsAWholeCleanWindowBeforeRelease() {
        var window = AudioDecoder.ResamplerDriftWindow()
        let second: UInt64 = 1_000_000_000
        let initial = window.observe(driftMs: 0, now: 0)
        let excursion = window.observe(driftMs: 80, now: 59 * second)
        let failedWindowEnd = window.observe(driftMs: 80, now: 60 * second)
        let recovering = window.observe(driftMs: 80, now: 119 * second)
        let recovered = window.observe(driftMs: 80, now: 120 * second)
        #expect(initial)
        #expect(!excursion)
        #expect(!failedWindowEnd)
        #expect(!recovering)
        #expect(recovered)
    }

    @Test func newPlayoutSegmentDiscardsPriorDriftFailure() {
        let decoder = steadyDecoder()
        let now = DispatchTime.now().uptimeNanoseconds
        _ = decoder.resamplerDriftWindow.observe(driftMs: 0, now: now - 2_000_000_000)
        let stable = decoder.resamplerDriftWindow.observe(driftMs: 80, now: now - 1_000_000_000)
        #expect(!stable)
        decoder.meterSampleRate = 48_000
        decoder.cushionLinkResolved = true
        decoder.lastResamplerUpdateNanos = now
        #expect(!decoder.meterRegisterScheduleOrOverrun(frames: 240))
        decoder.publishAudioState()
        #expect(decoder.resamplerSkewConverged)
    }

    @Test func reorderedDriftSamplesCannotPoisonAHealthyWindow() {
        var window = AudioDecoder.ResamplerDriftWindow()
        let second: UInt64 = 1_000_000_000
        _ = window.observe(driftMs: 0, now: 0)
        let rolledOver = window.observe(driftMs: 12, now: 60 * second)
        let older = window.observe(driftMs: 100, now: 59 * second)
        let repeated = window.observe(driftMs: 100, now: 60 * second)
        let next = window.observe(driftMs: 12.2, now: 61 * second)
        #expect(rolledOver)
        #expect(older)
        #expect(repeated)
        #expect(next)
    }

    @Test func reorderedDriftSamplesCannotClearAFailedWindow() {
        var window = AudioDecoder.ResamplerDriftWindow()
        let second: UInt64 = 1_000_000_000
        _ = window.observe(driftMs: 0, now: 0)
        _ = window.observe(driftMs: 80, now: 59 * second)
        let failedWindow = window.observe(driftMs: 80, now: 60 * second)
        let older = window.observe(driftMs: 0, now: 59 * second)
        let repeated = window.observe(driftMs: 0, now: 60 * second)
        let recovering = window.observe(driftMs: 80, now: 119 * second)
        let recovered = window.observe(driftMs: 80, now: 120 * second)
        let delayedFailure = window.observe(driftMs: 160, now: 119 * second)
        #expect(!failedWindow)
        #expect(!older)
        #expect(!repeated)
        #expect(!recovering)
        #expect(recovered)
        #expect(delayedFailure)
    }
}
