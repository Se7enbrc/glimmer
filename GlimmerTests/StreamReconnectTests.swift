//
//  StreamReconnectTests.swift
//
//  The silent reconnect's decisions: how much budget a sleep spends, and when
//  a PC-sent terminate means the PC ended the session rather than dropped it.
//

import Foundation
import Testing
@testable import Glimmer

struct StreamReconnectTests {

    // MARK: - Awake-time budget

    @Test func sleepingThroughTheEpisodeSpendsNoBudget() throws {
        let start = SuspendingClock.now
        let budget = ReconnectBudget(seconds: 30, now: start)
        // 10 s awake, then an hour asleep: 20 s are left, counted from the wake.
        let wake = Date(timeIntervalSinceReferenceDate: 3_600)
        let deadline = try #require(budget.deadline(now: start.advanced(by: .seconds(10)), wallNow: wake))
        #expect(abs(deadline.timeIntervalSince(wake) - 20) < 0.001)
    }

    @Test func spentBudgetHasNoDeadline() {
        let start = SuspendingClock.now
        let budget = ReconnectBudget(seconds: 30, now: start)
        #expect(budget.deadline(now: start.advanced(by: .seconds(30)), wallNow: Date()) == nil)
        #expect(budget.deadline(now: start.advanced(by: .seconds(45)), wallNow: Date()) == nil)
    }

    // MARK: - Did the PC end the session?

    @Test func pcThatQuitTheAppEndedTheSession() {
        #expect(StreamSession.pcEndedSession(runningAppID: 0, appID: 881))
    }

    @Test func pcRunningAnotherAppEndedTheSession() {
        #expect(StreamSession.pcEndedSession(runningAppID: 42, appID: 881))
    }

    @Test func pcStillRunningOurAppIsWorthAReconnect() {
        #expect(!StreamSession.pcEndedSession(runningAppID: 881, appID: 881))
    }

    /// Sunshine restarting doesn't answer; that's the case a reconnect rides out.
    @Test func silentPcIsWorthAReconnect() {
        #expect(!StreamSession.pcEndedSession(runningAppID: nil, appID: 881))
        #expect(!StreamSession.pcEndedSession(runningAppID: 0, appID: nil))
    }

    // MARK: - Reconnect log cause

    @Test func ourOwnDeadPeerDoesNotBlameAPcRestart() {
        let cause = StreamSession.reconnectCause(code: StreamSession.deadPeerTerminationCode)
        #expect(!cause.contains("restart"))
        #expect(cause.contains("-1"))
    }

    @Test func pcSentCodeIsNamedInHex() {
        let cause = StreamSession.reconnectCause(code: Int32(bitPattern: 0x80030023))
        #expect(cause.contains("0x80030023"))
    }

    @Test func stoppedBackendRejectsResourceAdoption() {
        let backend = NativeBackend()
        var adopted = false
        #expect(backend.adoptWhileConnecting { adopted = true })
        #expect(adopted)
        backend.stopConnection()
        adopted = false
        #expect(!backend.adoptWhileConnecting { adopted = true })
        #expect(!adopted)
    }

    @Test(arguments: [false, true])
    func connectionStartedIsNotPublishedAfterStop(interruptOnly: Bool) throws {
        let backend = NativeBackend()
        var publications = 0
        try backend.publishConnectionStarted { publications += 1 }
        #expect(publications == 1)

        if interruptOnly { backend.interruptConnection() } else { backend.stopConnection() }
        do {
            try backend.publishConnectionStarted { publications += 1 }
            Issue.record("Stopped startup reported success")
        } catch {
            guard case .interrupted = error as? EnetError else {
                Issue.record("Expected interruption, got \(error)")
                return
            }
        }
        #expect(publications == 1)
    }

    @Test(arguments: [false, true])
    func stoppedBackendRejectsControllerFeedback(interruptOnly: Bool) throws {
        let backend = NativeBackend()
        let enet = EnetControlChannel(host: .ipv4(.loopback), port: 0, controlConnectData: 0,
                                      crypto: try ControlCrypto(rikey: [UInt8](repeating: 0, count: 16)))
        backend.withState { backend.enetChannel = enet }
        if interruptOnly { backend.interruptConnection() } else { backend.stopConnection() }

        #expect(!backend.wireControllerFeedback(enet: enet, events: NativeConnectionEvents()))
        #expect(enet.onTeardown == nil)
        #expect(enet.onRumble == nil)
        #expect(enet.onSetMotionEvent == nil)
    }

    // MARK: - Frame watchdog after reconnect

    @MainActor @Test func reconnectClearsThePreviousDecodeGateLift() {
        let decoder = VideoDecoder()
        decoder.presentSuppressedLock.lock()
        decoder._decodeGateLiftedAtNanos = DispatchTime.now().uptimeNanoseconds
        decoder.presentSuppressedLock.unlock()
        #expect(decoder.secondsSinceDecodeGateLifted().isFinite)

        decoder.reapplySuppressionAtConnect()

        #expect(decoder.secondsSinceDecodeGateLifted() == .infinity)
    }

    @Test func staleGateLiftDoesNotCountAsDecodeProgress() {
        #expect(StreamSession.watchdogDecodeIdle(
            sinceDecoded: .infinity, sinceGateLift: 60, sinceArm: 0.5).isInfinite)
    }

    @Test func freshGateLiftStartsAnewIdleClock() {
        #expect(StreamSession.watchdogDecodeIdle(
            sinceDecoded: .infinity, sinceGateLift: 0.2, sinceArm: 5) == 0.2)
    }

    @Test func noGateLiftUsesTheDecodedFrameClock() {
        #expect(StreamSession.watchdogDecodeIdle(
            sinceDecoded: 1, sinceGateLift: .infinity, sinceArm: 5) == 1)
    }

    @Test func noGateLiftOrDecodedFrameAwaitsFirstFrame() {
        #expect(StreamSession.watchdogDecodeIdle(
            sinceDecoded: .infinity, sinceGateLift: .infinity, sinceArm: 0.5).isInfinite)
    }

    @Test func freshGateLiftShortensDecodedIdle() {
        #expect(StreamSession.watchdogDecodeIdle(
            sinceDecoded: 100, sinceGateLift: 3, sinceArm: 200) == 3)
    }
}
