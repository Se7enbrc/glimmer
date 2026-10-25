// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import AVFAudio
import Foundation
import Testing
@testable import GlimmerEngine

struct AudioSoakTests {
    @Test func thirtyTwoMinutePCMHasNoCleanWindowUnderrunDrift() throws {
        let queue = AudioPCMQueue(capacity: 4_800, channels: 1)
        let input = try buffer()
        let output = try buffer()
        let samples = try #require(input.floatChannelData)
        samples[0].update(repeating: 0.25, count: 480)
        var transport = SoakTransport()
        var rejectedWrites = 0
        var renderErrors = 0
        var maximumFill: UInt64 = 0
        var disabledUnderruns: UInt64 = 0
        var cleanUnderruns: UInt64 = 0
        var endFills: [UInt64] = []
        var expectedWritten: UInt64 = 0
        for _ in 0..<3 where queue.write(samples, frames: 480, isSilence: false) {
            expectedWritten += 480
        }
        for step in 0..<(SoakTransport.duration * 100) {
            let now = Double(step) / 100
            let phase = (step / 100) % SoakTransport.cycle
            let paused = phase == 60 || (70..<73).contains(phase) || phase == 90
            queue.enabled.store(!paused, ordering: .releasing)
            if !paused { transport.send(sequence: step, at: now, faults: SoakTransport.faults(at: now)) }
            for _ in transport.receive(through: now) {
                if queue.write(samples, frames: 480, isSilence: false) {
                    expectedWritten += 480
                } else {
                    rejectedWrites += 1
                }
            }
            let beforeRender = queue.underruns.load(ordering: .acquiring)
            if queue.render(frames: 480, buffers: output.mutableAudioBufferList) != noErr { renderErrors += 1 }
            let snapshot = queue.observation()
            let observation = try #require(snapshot)
            if paused { disabledUnderruns += observation.underruns - beforeRender }
            let fill = queue.written.load(ordering: .acquiring) - observation.frames
            maximumFill = max(maximumFill, fill)
            if step % 12_000 == 10_000 { cleanUnderruns = observation.underruns }
            if step % 12_000 == 11_999 {
                #expect(observation.underruns == cleanUnderruns, "Underrun drift at \(now)s")
                #expect(observation.silence == 0)
                endFills.append(fill)
            }
        }
        #expect(endFills.count == 16)
        #expect((endFills.max() ?? 0) - (endFills.min() ?? 0) <= 480)
        #expect(maximumFill < 4_800)
        #expect(rejectedWrites == 0 && renderErrors == 0 && disabledUnderruns == 0)
        #expect(queue.written.load(ordering: .acquiring) == expectedWritten)
        #expect(queue.underruns.load(ordering: .acquiring) > 0)
        #expect(transport.lost > 0 && transport.reordered > 0)
    }

    private func buffer() throws -> AVAudioPCMBuffer {
        let format = try #require(AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 1))
        let buffer = try #require(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 480))
        buffer.frameLength = 480
        return buffer
    }
}

extension AudioSoakTests {
    @Test(arguments: [40.0, -80.0])
    func thirtyTwoMinuteClockSkewDoesNotDrainTheCushion(skewPpm: Double) {
        let decoder = AudioDecoder(platform: dormantPlatform())
        let target = 30.0
        decoder.resamplerSetpointMs = target
        var fill = target
        var minimum = fill
        var maximum = fill
        var finalCorrection = 0.0
        for tick in 0..<(SoakTransport.duration * 4) {
            let elapsed = Double(tick) / 4
            let routeSkew = elapsed < 960 ? skewPpm : -skewPpm
            let now = UInt64(100_000_000_000) + UInt64(tick) * 250_000_000
            if tick == 960 * 4 {
                decoder.audioMeterLock.lock()
                decoder.cushionHostLabel = "soak"
                decoder.resamplerSkewMemoryKey = AudioDecoder.resamplerSkewKey(host: "soak", deviceUID: "old")
                decoder.noteOutputDeviceLocked(uid: "replacement")
                decoder.audioMeterLock.unlock()
            }
            decoder.driveResampler(fillMs: fill, targetMs: target, engaged: true, at: now)
            decoder.routeListenerQueue.sync {}
            fill += (routeSkew - decoder.resamplerEpsPpm) * 0.25 / 1_000
            minimum = min(minimum, fill)
            maximum = max(maximum, fill)
            if tick >= (SoakTransport.duration - 300) * 4 { finalCorrection += decoder.resamplerEpsPpm }
        }
        #expect(minimum > 0, "Clock skew must not consume the entire cushion")
        #expect(maximum < 60, "Clock skew must not accumulate an extra cushion")
        #expect(abs(fill - target) < 3)
        #expect(abs(finalCorrection / 1_200 + skewPpm) < 20)
        #expect(decoder.resamplerSkewMemoryKey.isEmpty)
    }

    private func dormantPlatform() -> AudioPlatform {
        AudioPlatform(makeOutput: { _ in
            Issue.record("The clock-skew soak must not open an audio device")
            throw CocoaError(.featureUnsupported)
        }, sampleRoute: { AudioRoute(label: "Test", uid: nil) },
        installRouteListener: { _, _, _ in }, removeRouteListener: { _ in },
        installDeviceListeners: { _, _ in }, removeDeviceListeners: {},
        captureVolume: { { AudioOutputVolume(volume: nil, muted: nil, routeChanged: false) } },
        environment: { AudioEnvironment(host: "unknown", link: "wired", jitterMs: 0) })
    }
}
