//
//  AudioPlayoutStallTests.swift
//
//  Coverage for the playout-stall watchdog (the 2026-08-12 overnight wedge:
//  audio resumed after a 9h host-idle stretch, the player node consumed zero
//  frames, and every arriving packet was dropped at the backlog gates for the
//  rest of the session - received, decoded, discarded, silent until reconnect).
//
//  The DETECTION half is a pure meter-state machine (audioMeterLock words, no
//  AV calls), so it is testable exactly like the downshift controller: set the
//  meter state a wedged session exhibits, drive the schedule/completion
//  entry points, and assert the latch. The REBUILD half
//  (`recoverIfPlayoutStalled`) makes real AVAudio calls and is exercised live,
//  not here - these tests prove the latch protocol around it: when it arms,
//  when it must not, and that the recovery episode's completion burst cannot
//  mint under-run evidence.
//

import Foundation
import Testing
@testable import Glimmer

/// `.serialized`: two tests here bracket the SHARED `audioUnderrunTotal`
/// counter with before/after reads (the evidence-gate pair), and parallel
/// execution can interleave the control's +1 inside the gate test's window -
/// an observed flake, not a hypothetical.
@Suite(.serialized)
struct AudioPlayoutStallTests {

    /// A meter in the wedged session's exact state: playout started and primed,
    /// a backlog pinned past the over-run ceiling (340ms default: 1s scheduled,
    /// nothing played), grace expired - so the ceiling branch drops the packet.
    private func wedgedDecoder() -> AudioDecoder {
        let decoder = AudioDecoder()
        decoder.audioMeterLock.lock()
        decoder.meterSampleRate = 48_000
        decoder.playoutStarted = true
        decoder.primed = true
        decoder.playoutDrained = false
        decoder.framesScheduled = 48_000   // 1000ms scheduled...
        decoder.framesPlayed = 0           // ...none consumed - the frozen node
        decoder.gateGraceUntilNanos = 0    // grace long expired
        decoder.audioMeterLock.unlock()
        return decoder
    }

    // MARK: - Detection latch

    /// The wedge: consumption dark past the threshold while a drop fires - the
    /// drop must latch the stall verdict (and still drop the packet; recovery
    /// belongs to the decode path, not the meter).
    @Test func ancientProgressLatchesStallOnDrop() {
        let decoder = wedgedDecoder()
        decoder.lastPlayoutProgressNanos = 1   // ancient (way past the 3s threshold)
        let dropped = decoder.meterRegisterScheduleOrOverrun(frames: 240)
        #expect(dropped)
        #expect(decoder.playoutStallPending)
    }

    /// A healthy session dropping at the ceiling (a genuine burst) has FRESH
    /// completion progress - the ceiling backstop must keep working exactly as
    /// before, with no stall verdict.
    @Test func freshProgressDropsWithoutLatching() {
        let decoder = wedgedDecoder()
        decoder.lastPlayoutProgressNanos = DispatchTime.now().uptimeNanoseconds
        let dropped = decoder.meterRegisterScheduleOrOverrun(frames: 240)
        #expect(dropped)
        #expect(!decoder.playoutStallPending)
    }

    /// No progress stamp at all (playout never started its clock) must not
    /// latch - the guard is `!= 0`, so a zero stamp can never read as "ancient".
    @Test func zeroProgressStampNeverLatches() {
        let decoder = wedgedDecoder()
        decoder.lastPlayoutProgressNanos = 0
        _ = decoder.meterRegisterScheduleOrOverrun(frames: 240)
        #expect(!decoder.playoutStallPending)
    }

    /// A recovery attempt just ran: further drops inside the retry window must
    /// NOT re-latch - a truly dead output device retries on the bounded
    /// cadence instead of thrashing the node/engine per dropped packet.
    @Test func recentRecoveryAttemptSuppressesRelatch() {
        let decoder = wedgedDecoder()
        decoder.lastPlayoutProgressNanos = 1
        decoder.stallRecoveryLastAttemptNanos = DispatchTime.now().uptimeNanoseconds
        _ = decoder.meterRegisterScheduleOrOverrun(frames: 240)
        #expect(!decoder.playoutStallPending)
    }

    // MARK: - The (re)arm edge

    /// The arm edge ends a recovery episode and starts the stall clock: it must
    /// clear `meterRecovering` and stamp fresh progress (a paused cold pre-roll
    /// begins its 3s window here, so it can never read as a stall).
    @Test func armEdgeClearsRecoveryAndStampsProgress() {
        let decoder = AudioDecoder()
        decoder.audioMeterLock.lock()
        decoder.meterSampleRate = 48_000
        decoder.playoutStarted = true
        decoder.playoutDrained = true      // the drain forces the re-arm edge
        decoder.primed = true
        decoder.meterRecovering = true
        decoder.audioMeterLock.unlock()
        let dropped = decoder.meterRegisterScheduleOrOverrun(frames: 240)
        #expect(!dropped)                  // the re-arm packet schedules
        #expect(!decoder.meterRecovering)
        #expect(decoder.lastPlayoutProgressNanos != 0)
        #expect(!decoder.playoutDrained)
    }

    // MARK: - Recovery evidence gate

    /// The recovery's `playerNode.stop()` fires a completion burst whose last
    /// completion drains the playhead exactly like a starvation drain. Gated on
    /// `meterRecovering` it must count NOTHING - un-gated it would ratchet the
    /// cushion target and persist the floor (the disguised-permanent-pin class
    /// the shutdown gate already blocks).
    @Test func recoveryCompletionBurstMintsNoUnderrun() {
        let decoder = AudioDecoder()
        decoder.audioMeterLock.lock()
        decoder.meterSampleRate = 48_000
        decoder.playoutStarted = true
        decoder.primed = true
        decoder.playoutDrained = false
        decoder.framesScheduled = 240
        decoder.framesPlayed = 0
        decoder.meterRecovering = true
        decoder.audioMeterLock.unlock()
        let before = TelemetryCounters.shared.audioUnderrunTotal.value
        decoder.meterCompleteOnePlayout(frames: 240)   // drains to empty
        #expect(TelemetryCounters.shared.audioUnderrunTotal.value == before)
        #expect(decoder.playoutDrained)                // bookkeeping still runs
        #expect(decoder.lastPlayoutProgressNanos != 0) // progress still stamps
    }

    /// Control for the gate test: the SAME drain WITHOUT the recovery latch is
    /// a real under-run and must count - proving the setup above genuinely
    /// reaches the under-run edge (the no-count result is the gate, not a
    /// mis-arranged test).
    @Test func realDrainStillCountsUnderrun() {
        let decoder = AudioDecoder()
        decoder.audioMeterLock.lock()
        decoder.meterSampleRate = 48_000
        decoder.playoutStarted = true
        decoder.primed = true
        decoder.playoutDrained = false
        decoder.framesScheduled = 240
        decoder.framesPlayed = 0
        decoder.audioMeterLock.unlock()
        let before = TelemetryCounters.shared.audioUnderrunTotal.value
        decoder.meterCompleteOnePlayout(frames: 240)
        #expect(TelemetryCounters.shared.audioUnderrunTotal.value == before + 1)
    }

    // MARK: - Flow-resume hygiene (the receiver's ≥2s-gap edge)

    /// Flow resuming with the drain edge MISSING (frozen completions - the
    /// wedge's precursor) must force the drained latch so the next schedule
    /// takes the re-arm edge (drift re-anchor + cushion rebuild).
    @Test func flowResumeForcesMissedDrainEdge() {
        let decoder = AudioDecoder()
        decoder.audioMeterLock.lock()
        decoder.playoutStarted = true
        decoder.playoutDrained = false
        decoder.audioMeterLock.unlock()
        decoder.notePacketFlowResumed(afterGapMs: 9_000)
        #expect(decoder.playoutDrained)
    }

    /// Before playout ever starts, a flow-resume edge is meaningless and must
    /// change nothing (no false drain on a cold session's first packets).
    @Test func flowResumeBeforePlayoutIsANoop() {
        let decoder = AudioDecoder()
        decoder.notePacketFlowResumed(afterGapMs: 9_000)
        #expect(!decoder.playoutDrained)
    }
}
