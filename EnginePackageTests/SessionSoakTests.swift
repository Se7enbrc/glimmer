// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import CoreMedia
import Testing
@testable import GlimmerEngine

@MainActor
struct SessionSoakTests {
    @Test(arguments: [(60, 60), (120, 120), (240, 240), (190, 240)])
    func thirtyTwoMinuteCadenceRecovers(contentHz: Int, refreshHz: Int) throws {
        let pacer = FramePacer(stats: StatsCollector(), configuredFps: Int32(refreshHz))
        pacer.running = true
        pacer.tickDeficit.warmingUp = false
        // Exercise the queued tick path without a display link or asynchronous submit handoff.
        pacer.variableRefreshEnabled = true
        let sample = try sampleBuffer()
        var transport = SoakTransport()
        var source = 0
        var window = Window()
        var cleanWindows: [Int] = []
        var maximumDepth = 0
        for tick in 0..<(SoakTransport.duration * refreshHz) {
            let now = Double(tick) / Double(refreshHz)
            let second = tick / refreshHz
            let phase = second % SoakTransport.cycle
            if tick.isMultiple(of: refreshHz) {
                transition(pacer, phase: phase)
                if phase == 100 { window = Window() }
            }
            while Double(source) / Double(contentHz) <= now + 1e-9 {
                let sent = Double(source) / Double(contentHz)
                transport.send(sequence: source, at: sent, faults: SoakTransport.faults(at: sent))
                source += 1
            }
            for packet in transport.receive(through: now) {
                pacer.submit(sample, hostPTS: CMTime(seconds: packet.sent, preferredTimescale: 90_000))
            }
            maximumDepth = max(maximumDepth, pacer.queue.count)
            let entry = (80..<82).contains(phase) ? nil : drain(pacer, now: now, refreshHz: refreshHz)
            if phase >= 100, let entry {
                window.releases += 1
                window.maximumAge = max(window.maximumAge, now - entry.hostPTSSeconds)
            }
            if (tick + 1).isMultiple(of: SoakTransport.cycle * refreshHz) {
                #expect(window.releases >= contentHz * 20 - 2, "Recovery window ending at \(second)s")
                #expect(window.maximumAge <= 3.0 / Double(contentHz), "Queue latency at \(second)s")
                #expect(pacer.queue.count <= 2)
                cleanWindows.append(window.releases)
            }
        }
        #expect(cleanWindows.count == 16)
        #expect((cleanWindows.max() ?? 0) - (cleanWindows.min() ?? 0) <= 2)
        #expect(maximumDepth <= FramePacer.maxQueuedFrames)
        #expect(transport.peakPending < 32)
        #expect(transport.lost > 0 && transport.reordered > 0)
        #expect(pacer.ptsDeltas.count <= 64 && pacer.sortedPtsDeltas.count <= 64)
        #expect(abs(pacer.contentFrameIntervalSeconds - 1 / Double(contentHz)) < 0.0001)
    }

    private struct Window {
        var releases = 0
        var maximumAge = 0.0
    }

    private func transition(_ pacer: FramePacer, phase: Int) {
        switch phase {
        case 50, 70: pacer.setPresentSuppressed(true)
        case 52, 73: pacer.setPresentSuppressed(false)
        case 90: pacer.clearQueue(reason: "soak reconnect")
        default: break
        }
    }

    private func drain(_ pacer: FramePacer, now: Double, refreshHz: Int) -> FramePacer.Entry? {
        pacer.lock.lock()
        defer { pacer.lock.unlock() }
        guard !pacer.presentSuppressed else {
            #expect(pacer.queue.count <= 1)
            return nil
        }
        _ = pacer.gapAwareTrimLocked(now: now, effectiveTarget: 1)
        let gate = pacer.dequeueDueFrameLocked(targetTimestamp: now,
            vsyncInterval: 1 / Double(refreshHz), effectiveTarget: 1)
        pacer.updateGapRecoveryLocked(presented: gate.toPresent != nil, empty: pacer.queue.isEmpty, now: now)
        if gate.toPresent != nil { pacer.liveness.releaseCount += 1 }
        return gate.toPresent
    }

    @Test func fakeTransportReplaysExactLossJitterAndReorder() {
        func replay() -> [SoakTransport.Packet] {
            var transport = SoakTransport()
            for sequence in 0..<100 {
                transport.send(sequence: sequence, at: Double(sequence) / 120,
                    faults: .init(lossEvery: 7, jitter: 0.005, reorderEvery: 3, reorderDelay: 0.04))
            }
            return transport.receive(through: 2)
        }
        let packets = replay()
        #expect(packets == replay())
        #expect(packets.count == 85)
        #expect(packets.allSatisfy { !$0.sequence.isMultiple(of: 7) })
        #expect(packets.map(\.sequence) != packets.map(\.sequence).sorted())
    }

    private func sampleBuffer() throws -> CMSampleBuffer {
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreate(allocator: nil, dataBuffer: nil, dataReady: true,
            makeDataReadyCallback: nil, refcon: nil, formatDescription: nil, sampleCount: 0,
            sampleTimingEntryCount: 0, sampleTimingArray: nil, sampleSizeEntryCount: 0,
            sampleSizeArray: nil, sampleBufferOut: &sample)
        #expect(status == noErr)
        return try #require(sample)
    }
}
