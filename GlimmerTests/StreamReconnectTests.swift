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

    // MARK: - A give-up names the fix

    /// A PC that slept mid-stream fails every attempt without answering; the give-up must say so and
    /// offer Wake and Connect, not "ended unexpectedly" with Try Again. Once the PC has answered, a
    /// deadline means the app was slow, and a classified failure keeps its own copy.
    @Test func reconnectGiveUpKeepsTheLastAttemptsCause() {
        let asleep = StreamSession.reconnectAttemptError(StreamError.hostTimedOut, pcAnswered: false)
        guard case .hostUnreachable = asleep else {
            Issue.record("an unanswered reconnect deadline should read as unreachable, got \(String(describing: asleep))")
            return
        }
        guard case .hostTimedOut = StreamSession.reconnectAttemptError(StreamError.hostTimedOut, pcAnswered: true) else {
            Issue.record("a deadline after the PC answered is the app being slow")
            return
        }
        guard case .streamPortsBlocked("UDP", 47999) = StreamSession.reconnectAttemptError(
            StreamError.streamPortsBlocked(proto: "UDP", port: 47999), pcAnswered: true) else {
            Issue.record("a classified failure must survive")
            return
        }
        #expect(StreamSession.reconnectAttemptError(CancellationError(), pcAnswered: false) == nil)
    }

    @MainActor @Test func giveUpWithAnUnreachablePcOffersWakeAndConnect() {
        let model = AppModel()
        let den = Host(id: "pc-1", name: "den", customName: "Den PC", localAddress: "192.0.2.10", manualAddress: nil,
                       apps: [], lastConnected: nil, serverCertPEM: nil, appVersion: nil, macAddress: nil)
        model.handleNativeEvent(
            .connectionTerminated(errorCode: -1, error: .hostUnreachable("the PC didn't answer")), host: den)
        #expect(model.nativeStreamError == AppModel.unreachableMessage("Den PC"))
        #expect(model.nativeStreamErrorKind == .unreachable)
        model.handleNativeEvent(.connectionTerminated(errorCode: -1), host: den)
        #expect(model.nativeStreamErrorKind == .other)
    }

    /// Picking another PC while one connects doesn't redirect the failed one's banner: its action
    /// still targets the PC the error names.
    @MainActor @Test func bannerActionTargetsThePcThatFailed() {
        let model = AppModel()
        let den = Host(id: "pc-1", name: "den", customName: "Den PC", localAddress: "192.0.2.10", manualAddress: nil,
                       apps: [], lastConnected: nil, serverCertPEM: nil, appVersion: nil, macAddress: nil)
        let tower = Host(id: "pc-2", name: "tower", customName: nil, localAddress: "192.0.2.20", manualAddress: nil,
                         apps: [], lastConnected: nil, serverCertPEM: nil, appVersion: nil, macAddress: nil)
        model.hosts = [den, tower]
        model.selectedHost = tower
        model.handleNativeEvent(
            .connectionTerminated(errorCode: -1, error: .hostUnreachable("the PC didn't answer")), host: den)
        #expect(model.streamErrorHost?.id == "pc-1")
    }

    /// Sunshine's own non-recoverable codes name their fix instead of "ended unexpectedly".
    @Test func sunshineTerminateCodesNameTheirFix() {
        let protected = AppModel.streamEndedMessage(
            code: StreamSession.protectedContentTerminationCode, hostName: "Den PC")
        let conversion = AppModel.streamEndedMessage(
            code: StreamSession.frameConversionTerminationCode, hostName: "Den PC")
        #expect(protected.hasPrefix("Den PC stopped the stream: the app is showing protected content"))
        #expect(conversion.contains("graphics driver") && conversion.hasPrefix("Den PC"))
        for message in [protected, conversion] {
            #expect(!message.localizedCaseInsensitiveContains("host") && !message.contains(" - "))
        }
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

    /// A reconnect inherits the old connection's decoded-frame clock. Counted from there, the first tick
    /// after the resume read a 6 s stall and asked for a keyframe Sunshine was already sending.
    @Test func reconnectArmFloorsTheInheritedDecodeClock() {
        #expect(StreamSession.watchdogDecodeIdle(
            sinceDecoded: 6, sinceGateLift: .infinity, sinceArm: 0.3) == 0.3)
    }

    // MARK: - Keyframe nudges back off

    /// One keyframe request at 2 s, then at 4, 8, 16 and every 16 s: a paused encoder answers the first,
    /// and a stalled path is not helped by one every second.
    @Test func keyframeNudgesBackOffThenHoldAtSixteenSeconds() {
        var nudge = DecodeStallNudge()
        var asked: [Double] = []
        for tick in stride(from: 0.5, through: 70, by: 1.0) where nudge.due(at: tick) { asked.append(tick) }
        #expect(asked == [2.5, 4.5, 8.5, 16.5, 32.5, 48.5, 64.5])
        #expect(DecodeStallNudge().nextAt == StreamSession.decodeStallRecoveryThreshold)
    }

    @MainActor @Test(arguments: [false, true])
    func lateEstablishedCannotRearmStoppedInput(stopping: Bool) async {
        let backend = NativeBackend()
        let session = StreamSession(backend: backend)
        let input = InputForwarder()
        await session.prepareCallbackTest(input: input, streaming: stopping, stopping: stopping)
        await session.nativeConnectionEstablished(from: backend)
        await Self.drainMainQueue()
        #expect(!input.isReady)
        #expect(await !session.reachedLiveState)
    }

    @MainActor @Test func oldBackendCannotMutateTheReplacementConnection() async {
        let old = NativeBackend()
        let current = NativeBackend()
        let session = StreamSession(backend: current)
        let input = InputForwarder()
        await session.prepareCallbackTest(input: input)
        await session.nativeConnectionEstablished(from: old)
        await Self.drainMainQueue()
        #expect(!input.isReady)
        #expect(await !session.reachedLiveState)
        input.setReady(true)
        await session.handleHostTerminate(code: 0, from: old)
        await Self.drainMainQueue()
        #expect(input.isReady)
        #expect(await session.isStreaming)
    }

    @MainActor @Test func ignoredTerminationCannotPauseReconnectingInput() async {
        let backend = NativeBackend()
        let session = StreamSession(backend: backend)
        let input = InputForwarder()
        input.setReady(true)
        await session.prepareCallbackTest(input: input, reconnecting: true)
        await session.handleHostTerminate(code: 0, from: backend)
        await Self.drainMainQueue()
        #expect(input.isReady)
        #expect(await session.isStreaming)
    }

    @MainActor @Test func currentEstablishedArmsLiveInput() async {
        let backend = NativeBackend()
        let session = StreamSession(backend: backend)
        let input = InputForwarder()
        await session.prepareCallbackTest(input: input)
        await session.nativeConnectionEstablished(from: backend)
        await Self.drainMainQueue()
        #expect(input.isReady)
        #expect(await session.reachedLiveState)
    }

    private static func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }
}

private extension StreamSession {
    func prepareCallbackTest(input: InputForwarder, streaming: Bool = true,
                             stopping: Bool = false, reconnecting: Bool = false) {
        self.input = input
        isStreaming = streaming
        stopInProgress = stopping
        isReconnecting = reconnecting
    }
}
