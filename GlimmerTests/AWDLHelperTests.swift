import Foundation
import Synchronization
import Testing

struct AWDLHelperTests {
    @MainActor @Test func enabledHelperSkipsStatusRefresh() {
        var refreshCount = 0
        AWDLStreamLease.refreshIfNeeded(isEnabled: { true }, refresh: { refreshCount += 1 })
        #expect(refreshCount == 0)
    }

    @MainActor @Test func freshlyApprovedHelperRefreshesBeforeStream() {
        var enabled = false
        AWDLStreamLease.refreshIfNeeded(isEnabled: { enabled }, refresh: { enabled = true })
        #expect(enabled)
    }

    @MainActor @Test func releaseWithoutHeartbeatDoesNothing() {
        var releaseCount = 0
        AWDLStreamLease.releaseIfHeartbeatExists(hasHeartbeat: { false }, release: { releaseCount += 1 })
        #expect(releaseCount == 0)
    }

    @MainActor @Test func releaseAfterSuppressionStartsRunsCleanup() {
        var releaseCount = 0
        AWDLStreamLease.releaseIfHeartbeatExists(hasHeartbeat: { true }, release: { releaseCount += 1 })
        #expect(releaseCount == 1)
    }

    @Test func releaseRepliesAfterRestore() async {
        let restoreStarted = DispatchSemaphore(value: 0)
        let allowRestore = DispatchSemaphore(value: 0)
        let replied = DispatchSemaphore(value: 0)
        let operations = Mutex<[String]>([])
        let suppressor = AWDLSuppressor(
            interfaceIsUp: { false },
            runIfconfig: { args in
                restoreStarted.signal()
                allowRestore.wait()
                operations.withLock { $0.append(args.last ?? "") }
                return true
            })
        let service = HelperService(suppressor: suppressor)

        service.setAWDLDown(false, reason: "test") { success in
            #expect(success)
            replied.signal()
        }
        #expect(await restoreStarted.waitAsync(for: .seconds(2)) == .success)
        #expect(replied.takeSignal() == .timedOut)
        allowRestore.signal()
        #expect(await replied.waitAsync(for: .seconds(2)) == .success)
        #expect(operations.withLock { $0 } == ["up"])
    }

    @Test func monotonicHeartbeatExpiresAtThresholds() {
        let start = ContinuousClock.now
        let clock = Mutex(start)
        let suppressor = AWDLSuppressor(
            interfaceIsUp: { false },
            runIfconfig: { _ in true },
            clockNow: { clock.withLock { $0 } })
        suppressor.setSuppressing(true, reason: "test")

        #expect(suppressor.withHeartbeatDecision(at: start + .seconds(2)) { $0 } == .suppressing)
        #expect(suppressor.withHeartbeatDecision(at: start + .seconds(4)) { $0 } == .stale(.seconds(4)))
        #expect(!suppressor.suppressing)
        #expect(suppressor.withHeartbeatDecision(at: start + .seconds(9)) { $0 } == .exit(.seconds(9)))
    }

    @Test func renewedHeartbeatWinsBeforeExpiry() {
        let start = ContinuousClock.now
        let clock = Mutex(start)
        let suppressor = AWDLSuppressor(
            interfaceIsUp: { false },
            runIfconfig: { _ in true },
            clockNow: { clock.withLock { $0 } })
        suppressor.setSuppressing(true, reason: "test")
        clock.withLock { $0 = start + .seconds(4) }
        suppressor.setSuppressing(true, reason: "heartbeat")

        #expect(suppressor.withHeartbeatDecision(at: start + .seconds(4)) { $0 } == .suppressing)
        #expect(suppressor.withHeartbeatDecision(at: start + .seconds(6)) { $0 } == .suppressing)
        #expect(suppressor.suppressing)
        #expect(suppressor.withHeartbeatDecision(at: start + .seconds(8)) { $0 } == .stale(.seconds(4)))
    }

    @Test func heartbeatWaitsForStaleRelease() async {
        await assertHeartbeatWaitsForDecision(after: .seconds(4), expected: .stale(.seconds(4)), suppressing: true)
    }

    @Test func heartbeatWaitsForIdleExitDecision() async {
        await assertHeartbeatWaitsForDecision(after: .seconds(9), expected: .exit(.seconds(9)), suppressing: false)
    }

    private func assertHeartbeatWaitsForDecision(
        after idle: Duration,
        expected: AWDLSuppressor.HeartbeatDecision,
        suppressing: Bool
    ) async {
        let start = ContinuousClock.now
        let clock = Mutex(start)
        let suppressor = AWDLSuppressor(interfaceIsUp: { false },
                                       runIfconfig: { _ in true }, clockNow: { clock.withLock { $0 } })
        if suppressing { suppressor.setSuppressing(true, reason: "test") }
        clock.withLock { $0 = start + idle }
        let decisionEntered = DispatchSemaphore(value: 0)
        let allowDecision = DispatchSemaphore(value: 0)
        let decisionFinished = DispatchSemaphore(value: 0)
        let heartbeatStarted = DispatchSemaphore(value: 0)
        let heartbeatFinished = DispatchSemaphore(value: 0)
        let decisions = Mutex<[AWDLSuppressor.HeartbeatDecision]>([])
        let decisionQueue = DispatchQueue(label: "awdl.test.decision", qos: .userInteractive)
        let heartbeatQueue = DispatchQueue(label: "awdl.test.heartbeat", qos: .userInteractive)

        decisionQueue.async {
            suppressor.withHeartbeatDecision(at: start + idle) { decision in
                decisions.withLock { $0.append(decision) }
                decisionEntered.signal()
                allowDecision.wait()
            }
            decisionFinished.signal()
        }
        #expect(await decisionEntered.waitAsync(for: .seconds(10)) == .success)
        heartbeatQueue.async {
            heartbeatStarted.signal()
            suppressor.setSuppressing(true, reason: "heartbeat")
            heartbeatFinished.signal()
        }
        #expect(await heartbeatStarted.waitAsync(for: .seconds(10)) == .success)
        #expect(await heartbeatFinished.waitAsync(for: .milliseconds(100)) == .timedOut)
        allowDecision.signal()
        #expect(await decisionFinished.waitAsync(for: .seconds(10)) == .success)
        #expect(await heartbeatFinished.waitAsync(for: .seconds(10)) == .success)
        #expect(decisions.withLock { $0 } == [expected])
        #expect(suppressor.suppressing)
    }
}
