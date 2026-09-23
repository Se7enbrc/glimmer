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
}
