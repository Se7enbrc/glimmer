import Combine
import Foundation
import ServiceManagement
import Synchronization
import Testing
@testable import Glimmer

@MainActor
private final class HelperGate {
    let entered = DispatchSemaphore(value: 0)
    private var continuation: CheckedContinuation<Void, Never>?

    func wait() async {
        await withCheckedContinuation {
            continuation = $0
            entered.signal()
        }
    }

    func open() {
        continuation?.resume()
        continuation = nil
    }
}

@MainActor
private final class HelperHarness {
    var status: SMAppService.Status = .enabled
    var events: [String] = []
    var gauge = false
    var releaseResults = [true]
    var unregisterFails = false
    var unregisterGate: HelperGate?
    var reachable = true
    var daemonJobMissing = false
    var releaseGate: HelperGate?
    var downGate: HelperGate?
    var client: HelperClient?
    var countGate: HelperGate?
    var registrationGate: HelperGate?
    var retryGate: HelperGate?
    var recoveryGate: HelperGate?
    var retryDelays: [Duration] = []
    var persistentReleaseFailure = false
    var releaseAcknowledged: (() -> Bool)?
    let tick = DispatchSemaphore(value: 0)
    let released = DispatchSemaphore(value: 0)
    let unregistered = DispatchSemaphore(value: 0)
    let registered = DispatchSemaphore(value: 0)
    private let defaults: UserDefaults
    private let suite = "AWDLTests.\(UUID().uuidString)"

    init() throws {
        defaults = try #require(UserDefaults(suiteName: suite))
    }

    func makeManager() -> AWDLHelperManager {
        AWDLHelperManager(operations: .init(
            status: { self.status },
            register: {
                self.events.append("register")
                self.status = .enabled
                self.registered.signal()
            },
            unregister: {
                self.events.append("unregister")
                await self.unregisterGate?.wait()
                self.unregistered.signal()
                if self.unregisterFails { throw CancellationError() }
                self.status = .notRegistered
            },
            setDown: { down, reason in
                self.events.append(down ? "down" : reason)
                if down {
                    if let client = self.client { return await client.setAWDLDown(true, reason: reason) }
                    await self.downGate?.wait()
                    return true
                }
                await self.releaseGate?.wait()
                let result = self.releaseAcknowledged?()
                    ?? (self.persistentReleaseFailure ? false : self.releaseResults.removeFirst())
                self.events.append(result ? "restored" : "release-failed")
                self.released.signal()
                return result
            },
            invalidate: { self.events.append("invalidate") },
            reachable: { self.reachable },
            count: {
                if let client = self.client { return await client.reSuppressCount() }
                await self.countGate?.wait()
                return 1
            },
            daemonJobMissing: { self.daemonJobMissing },
            sleep: { duration in
                if duration == .milliseconds(600) {
                    await self.registrationGate?.wait()
                    try Task.checkCancellation()
                } else if self.persistentReleaseFailure {
                    self.retryDelays.append(duration)
                    if self.retryDelays.count >= 4 { await self.recoveryGate?.wait() }
                } else if let retry = self.retryGate {
                    await retry.wait()
                } else {
                    self.tick.signal()
                    try await Task.sleep(for: .seconds(3600))
                }
            },
            telemetry: { suppressing, _ in self.gauge = suppressing }), defaults: defaults)
    }

    func cleanUp() { defaults.removePersistentDomain(forName: suite) }
}

@MainActor
struct AWDLHelperManagerTests {
    @Test(arguments: [false, true])
    func missingDaemonIsRecreatedBeforeRelease(disable: Bool) async throws {
        let harness = try HelperHarness()
        defer { harness.cleanUp() }
        let manager = harness.makeManager()
        manager.suppressForStream()
        #expect(await harness.tick.waitAsync(for: .seconds(10)) == .success)
        harness.reachable = false
        harness.daemonJobMissing = true
        harness.persistentReleaseFailure = true
        harness.releaseAcknowledged = { harness.events.contains("register") }
        if disable { manager.disable() } else { manager.releaseForStream() }
        #expect(await harness.registered.waitAsync(for: .seconds(10)) == .success)
        for _ in 0..<5 { #expect(await harness.released.waitAsync(for: .seconds(10)) == .success) }
        let registration = try #require(harness.events.firstIndex(of: "register"))
        let restoration = try #require(harness.events.firstIndex(of: "restored"))
        #expect(registration < restoration)
        #expect(harness.events.contains("restored"))
        if disable {
            #expect(await harness.unregistered.waitAsync(for: .seconds(10)) == .success)
            #expect(await harness.unregistered.waitAsync(for: .seconds(10)) == .success)
            #expect(!manager.isRegistered)
        } else {
            #expect(manager.isEnabled)
        }
    }

    @Test func idleReleaseDoesNotContactHelper() throws {
        let harness = try HelperHarness()
        defer { harness.cleanUp() }
        let manager = harness.makeManager()
        manager.releaseForStream()
        #expect(harness.events.isEmpty)
    }

    @Test(arguments: [false, true])
    func queuedHeartbeatDoesNotContactHelper(disable: Bool) async throws {
        let harness = try HelperHarness()
        defer { harness.cleanUp() }
        let manager = harness.makeManager()
        manager.suppressForStream()
        if !disable { manager.releaseForStream() }
        manager.disable()
        #expect(await harness.unregistered.waitAsync(for: .seconds(10)) == .success)
        #expect(harness.events == ["invalidate", "unregister"])
    }

    @Test func repeatedDisableWaitsForRestorationAndRejectsNewStreams() async throws {
        let harness = try HelperHarness()
        defer { harness.cleanUp() }
        let gate = HelperGate()
        harness.releaseGate = gate
        let manager = harness.makeManager()
        manager.suppressForStream()
        #expect(await harness.tick.waitAsync(for: .seconds(10)) == .success)
        #expect(harness.gauge)
        manager.disable()
        #expect(!harness.gauge)
        #expect(!manager.suppressing)
        #expect(!manager.isEnabled)
        #expect(!manager.isRegistered)
        #expect(await gate.entered.waitAsync(for: .seconds(10)) == .success)
        manager.disable()
        manager.refresh()
        manager.suppressForStream()
        #expect(harness.events == ["down", "user-disabled"])
        gate.open()
        #expect(await harness.unregistered.waitAsync(for: .seconds(10)) == .success)
        #expect(await harness.unregistered.waitAsync(for: .seconds(10)) == .success)
        #expect(harness.events == ["down", "user-disabled", "restored", "invalidate", "unregister", "invalidate", "unregister"])
    }

    @Test func enableImmediatelyFollowedByDisableDoesNotDeadlockOrRegister() async throws {
        let harness = try HelperHarness()
        defer { harness.cleanUp() }
        let manager = harness.makeManager()
        manager.enable()
        manager.disable()
        #expect(await harness.unregistered.waitAsync(for: .seconds(10)) == .success)
        #expect(harness.events == ["invalidate", "unregister"])
        #expect(!manager.isRegistered)
    }

    @Test func disableCancelsEnableDuringSettling() async throws {
        let harness = try HelperHarness()
        defer { harness.cleanUp() }
        let gate = HelperGate()
        harness.registrationGate = gate
        let manager = harness.makeManager()
        manager.enable()
        #expect(await gate.entered.waitAsync(for: .seconds(10)) == .success)
        #expect(await harness.unregistered.waitAsync(for: .seconds(10)) == .success)
        manager.disable()
        gate.open()
        #expect(await harness.unregistered.waitAsync(for: .seconds(10)) == .success)
        #expect(!harness.events.contains("register"))
        #expect(!manager.isEnabled)
    }

    @Test func disableInheritsPendingStreamRelease() async throws {
        let harness = try HelperHarness()
        defer { harness.cleanUp() }
        let gate = HelperGate()
        harness.releaseGate = gate
        let manager = harness.makeManager()
        manager.suppressForStream()
        #expect(await harness.tick.waitAsync(for: .seconds(10)) == .success)
        manager.releaseForStream()
        #expect(await gate.entered.waitAsync(for: .seconds(10)) == .success)
        manager.disable()
        #expect(harness.events == ["down", "stream-end"])
        gate.open()
        #expect(await harness.unregistered.waitAsync(for: .seconds(10)) == .success)
        #expect(harness.events == ["down", "stream-end", "restored", "invalidate", "unregister"])
    }

    @Test func failedReleaseRetriesAutomaticallyAndSurvivesAnotherDisable() async throws {
        let harness = try HelperHarness()
        defer { harness.cleanUp() }
        let manager = harness.makeManager()
        manager.suppressForStream()
        #expect(await harness.tick.waitAsync(for: .seconds(10)) == .success)
        harness.releaseResults = [false, true]
        let retry = HelperGate()
        harness.retryGate = retry
        manager.disable()
        #expect(await retry.entered.waitAsync(for: .seconds(10)) == .success)
        manager.disable()
        manager.suppressForStream()
        #expect(harness.events == ["down", "user-disabled", "release-failed"])
        harness.retryGate = nil
        retry.open()
        #expect(await harness.unregistered.waitAsync(for: .seconds(10)) == .success)
        #expect(await harness.unregistered.waitAsync(for: .seconds(10)) == .success)
        #expect(harness.events.prefix(6) == ["down", "user-disabled", "release-failed", "user-disabled", "restored", "invalidate"])
    }

    @Test(arguments: [false, true])
    func blockedInterfaceRestorationPreventsTeardown(queueEnable: Bool) async throws {
        let harness = try HelperHarness()
        defer { harness.cleanUp() }
        let manager = harness.makeManager()
        manager.suppressForStream()
        #expect(await harness.tick.waitAsync(for: .seconds(10)) == .success)
        let started = DispatchSemaphore(value: 0)
        let unblock = DispatchSemaphore(value: 0)
        let acknowledged = DispatchSemaphore(value: 0)
        let restored = Mutex(false)
        let suppressor = AWDLSuppressor(interfaceIsUp: { restored.withLock { $0 } }, runIfconfig: { _ in
            started.signal()
            unblock.wait()
            restored.withLock { $0 = true }
            return true
        })
        let service = HelperService(suppressor: suppressor)
        let completed = Mutex(false)
        service.setAWDLDown(false, reason: "test") { success in
            completed.withLock { $0 = success }
            acknowledged.signal()
        }
        #expect(await started.waitAsync(for: .seconds(10)) == .success)
        harness.releaseAcknowledged = { completed.withLock { $0 } }
        harness.reachable = false
        harness.persistentReleaseFailure = true
        let recovery = HelperGate()
        harness.recoveryGate = recovery
        manager.disable()
        #expect(await recovery.entered.waitAsync(for: .seconds(10)) == .success)
        if queueEnable { manager.enable() }
        for _ in 0..<5 {
            #expect(!harness.events.contains("unregister"))
            #expect(!harness.events.contains("register"))
            #expect(!restored.withLock { $0 })
            recovery.open()
            if await recovery.entered.waitAsync(for: .seconds(1)) != .success { break }
        }
        #expect(!harness.events.contains("unregister"))
        #expect(!manager.isEnabled)
        #expect(harness.events.filter { $0 == "release-failed" }.count >= 8)
        unblock.signal()
        #expect(await acknowledged.waitAsync(for: .seconds(10)) == .success)
        recovery.open()
        #expect(await harness.unregistered.waitAsync(for: .seconds(10)) == .success)
        #expect(restored.withLock { $0 })
        if queueEnable {
            #expect(await harness.registered.waitAsync(for: .seconds(10)) == .success)
            #expect(manager.isEnabled)
            manager.disable()
            #expect(await harness.unregistered.waitAsync(for: .seconds(10)) == .success)
        }
    }

    @Test(arguments: [false, true])
    func failedReleasesWaitForDelayedRestoration(disable: Bool) async throws {
        let harness = try HelperHarness()
        defer { harness.cleanUp() }
        let manager = harness.makeManager()
        manager.suppressForStream()
        #expect(await harness.tick.waitAsync(for: .seconds(10)) == .success)
        harness.persistentReleaseFailure = true
        harness.releaseResults = [true, true]
        let recovery = HelperGate()
        harness.recoveryGate = recovery
        if disable { manager.disable() } else { manager.releaseForStream() }
        #expect(await recovery.entered.waitAsync(for: .seconds(10)) == .success)
        #expect(harness.retryDelays == [.seconds(1), .seconds(2), .seconds(4), .seconds(10)])
        #expect(harness.events.filter { $0 == "release-failed" }.count == 4)
        if !disable { manager.suppressForStream() }
        recovery.open()
        #expect(await recovery.entered.waitAsync(for: .seconds(1)) == .success)
        #expect(harness.events.filter { $0 == "release-failed" }.count == 5)
        #expect(harness.retryDelays.last == .seconds(10))
        #expect(!harness.events.contains("unregister"))
        #expect(harness.events.filter { $0 == "down" }.count == 1)
        #expect(!manager.isEnabled)
        let restoration = HelperGate()
        harness.releaseGate = restoration
        harness.persistentReleaseFailure = false
        recovery.open()
        #expect(await restoration.entered.waitAsync(for: .seconds(1)) == .success)
        #expect(!harness.events.contains("unregister"))
        #expect(harness.events.filter { $0 == "down" }.count == 1)
        #expect(!manager.isEnabled)
        harness.releaseGate = nil
        restoration.open()
        if disable {
            #expect(await harness.unregistered.waitAsync(for: .seconds(10)) == .success)
            #expect(!manager.isRegistered)
            #expect(harness.events.suffix(3) == ["restored", "invalidate", "unregister"])
        } else {
            #expect(await harness.tick.waitAsync(for: .seconds(10)) == .success)
            #expect(manager.isEnabled)
            #expect(harness.events.suffix(2) == ["restored", "down"])
            manager.disable()
            #expect(await harness.unregistered.waitAsync(for: .seconds(10)) == .success)
        }
    }

    @Test(arguments: [false, true])
    func streamDuringRestorationIsQueuedAndCanBeCancelled(endNextStream: Bool) async throws {
        let harness = try HelperHarness()
        defer { harness.cleanUp() }
        let manager = harness.makeManager()
        manager.suppressForStream()
        #expect(await harness.tick.waitAsync(for: .seconds(10)) == .success)
        let gate = HelperGate()
        harness.releaseGate = gate
        manager.releaseForStream()
        #expect(await gate.entered.waitAsync(for: .seconds(10)) == .success)
        manager.suppressForStream()
        #expect(harness.events == ["down", "stream-end"])
        if endNextStream { manager.releaseForStream() }
        harness.releaseGate = nil
        gate.open()
        #expect(await harness.released.waitAsync(for: .seconds(10)) == .success)
        if endNextStream {
            #expect(harness.events == ["down", "stream-end", "restored"])
        } else {
            #expect(await harness.tick.waitAsync(for: .seconds(10)) == .success)
            #expect(harness.events == ["down", "stream-end", "restored", "down"])
            harness.releaseResults = [true]
            manager.releaseForStream()
            #expect(await harness.released.waitAsync(for: .seconds(10)) == .success)
        }
    }

    @Test func failedUnregisterCannotOverrideOffIntentOrReconcile() async throws {
        let harness = try HelperHarness()
        defer { harness.cleanUp() }
        harness.unregisterFails = true
        let manager = harness.makeManager()
        manager.disable()
        #expect(await harness.unregistered.waitAsync(for: .seconds(10)) == .success)
        #expect(manager.state == .enabled)
        manager.suppressForStream()
        manager.reconcileAfterUpdate()
        #expect(!manager.isEnabled)
        #expect(!manager.isRegistered)
        #expect(harness.events == ["invalidate", "unregister"])
        let relaunched = harness.makeManager()
        relaunched.reconcileAfterUpdate()
        #expect(!relaunched.isEnabled)
    }

    @Test(arguments: [false, true])
    func cancelledHeartbeatCannotPublishLateReplies(duringCount: Bool) async throws {
        let harness = try HelperHarness()
        defer { harness.cleanUp() }
        let gate = HelperGate()
        if duringCount { harness.countGate = gate } else { harness.downGate = gate }
        let manager = harness.makeManager()
        manager.suppressForStream()
        #expect(await gate.entered.waitAsync(for: .seconds(10)) == .success)
        manager.disable()
        #expect(!harness.gauge)
        #expect(harness.events == ["down"])
        gate.open()
        #expect(await harness.unregistered.waitAsync(for: .seconds(10)) == .success)
        #expect(!manager.suppressing)
        #expect(!harness.gauge)
        #expect(harness.events == ["down", "user-disabled", "restored", "invalidate", "unregister"])
    }

    @Test(arguments: [false, true])
    func disableRestoresBeforeUnregisterWithSuspendedReply(duringCount: Bool) async throws {
        let harness = try HelperHarness()
        defer { harness.cleanUp() }
        let listener = NSXPCListener.anonymous()
        defer { listener.invalidate() }
        let endpoint = listener.endpoint
        let proxy = HelperTestProxy(suspendDown: !duringCount, suspendCount: duringCount)
        let client = HelperClient(makeConnection: { NSXPCConnection(listenerEndpoint: endpoint) },
                                  makeProxy: { _, _ in proxy })
        harness.client = client
        let release = HelperGate()
        harness.releaseGate = release
        let manager = harness.makeManager()
        manager.suppressForStream()
        #expect(await proxy.stalledEntered.waitAsync(for: .seconds(10)) == .success)
        manager.disable()
        let restored = await release.entered.waitAsync(for: .seconds(5)) == .success
        #expect(restored)
        #expect(!harness.events.contains("unregister"))
        #expect(!manager.isEnabled)
        // Drain the old implementation on failure without hiding its blocked teardown.
        if !restored {
            proxy.finishDown()
            #expect(await release.entered.waitAsync(for: .seconds(10)) == .success)
        }
        release.open()
        #expect(await harness.unregistered.waitAsync(for: .seconds(10)) == .success)
        proxy.finishDown()
        #expect(!manager.suppressing)
        #expect(!harness.gauge)
        #expect(harness.events == ["down", "user-disabled", "restored", "invalidate", "unregister"])
        await client.invalidate()
    }

    @Test func heartbeatAndUnchangedRefreshDoNotPublishButTeardownDoes() async throws {
        let harness = try HelperHarness()
        defer { harness.cleanUp() }
        let manager = harness.makeManager()
        let publications = Mutex(0)
        let observer = manager.objectWillChange.sink { publications.withLock { $0 += 1 } }
        defer { observer.cancel() }
        manager.refresh()
        manager.suppressForStream()
        #expect(await harness.tick.waitAsync(for: .seconds(10)) == .success)
        #expect(publications.withLock { $0 } == 0)
        manager.disable()
        #expect(publications.withLock { $0 } > 0)
        let beforeCompletion = publications.withLock { $0 }
        #expect(await harness.unregistered.waitAsync(for: .seconds(10)) == .success)
        #expect(publications.withLock { $0 } > beforeCompletion)
    }

    @Test func transientReleaseFailureRecoversQueuedStreamWithoutToggle() async throws {
        let harness = try HelperHarness()
        defer { harness.cleanUp() }
        let manager = harness.makeManager()
        manager.suppressForStream()
        #expect(await harness.tick.waitAsync(for: .seconds(10)) == .success)
        harness.releaseResults = [false, true, true]
        let retry = HelperGate()
        harness.retryGate = retry
        manager.releaseForStream()
        #expect(await retry.entered.waitAsync(for: .seconds(10)) == .success)
        #expect(!manager.isEnabled)
        manager.suppressForStream()
        harness.retryGate = nil
        retry.open()
        #expect(await harness.tick.waitAsync(for: .seconds(10)) == .success)
        #expect(manager.isEnabled)
        #expect(harness.events == ["down", "stream-end", "release-failed", "stream-end", "restored", "down"])
        #expect(await harness.released.waitAsync(for: .seconds(10)) == .success)
        #expect(await harness.released.waitAsync(for: .seconds(10)) == .success)
        manager.releaseForStream()
        #expect(await harness.released.waitAsync(for: .seconds(10)) == .success)
    }

    @Test func enableWaitsForPendingStreamRestoration() async throws {
        let harness = try HelperHarness()
        defer { harness.cleanUp() }
        let manager = harness.makeManager()
        manager.suppressForStream()
        #expect(await harness.tick.waitAsync(for: .seconds(10)) == .success)
        let gate = HelperGate()
        harness.releaseGate = gate
        manager.releaseForStream()
        #expect(await gate.entered.waitAsync(for: .seconds(10)) == .success)
        manager.enable()
        gate.open()
        #expect(await harness.registered.waitAsync(for: .seconds(10)) == .success)
        #expect(harness.events == ["down", "stream-end", "restored", "unregister", "register"])
        #expect(manager.isEnabled)
    }

    @Test func cancelledEnableCannotBypassAnOlderTeardown() async throws {
        let harness = try HelperHarness()
        defer { harness.cleanUp() }
        let gate = HelperGate()
        harness.unregisterGate = gate
        let manager = harness.makeManager()
        manager.disable()
        #expect(await gate.entered.waitAsync(for: .seconds(10)) == .success)
        manager.enable()
        manager.disable()
        #expect(harness.events == ["invalidate", "unregister"])
        harness.unregisterGate = nil
        gate.open()
        #expect(await harness.unregistered.waitAsync(for: .seconds(10)) == .success)
        #expect(await harness.unregistered.waitAsync(for: .seconds(10)) == .success)
        #expect(harness.events == ["invalidate", "unregister", "invalidate", "unregister"])
        #expect(!manager.isRegistered)
    }

    @Test func restorationPublishesAvailabilityEvenWhenServiceStatusDoesNotChange() async throws {
        let harness = try HelperHarness()
        defer { harness.cleanUp() }
        let manager = harness.makeManager()
        manager.suppressForStream()
        #expect(await harness.tick.waitAsync(for: .seconds(10)) == .success)
        let gate = HelperGate()
        harness.releaseGate = gate
        let publications = Mutex(0)
        let observer = manager.objectWillChange.sink { publications.withLock { $0 += 1 } }
        defer { observer.cancel() }
        manager.releaseForStream()
        #expect(!manager.isEnabled)
        #expect(manager.isRegistered)
        #expect(publications.withLock { $0 } == 1)
        #expect(await gate.entered.waitAsync(for: .seconds(10)) == .success)
        manager.refresh()
        #expect(publications.withLock { $0 } == 1)
        gate.open()
        #expect(await harness.released.waitAsync(for: .seconds(10)) == .success)
        #expect(manager.isEnabled)
        #expect(publications.withLock { $0 } == 2)
    }

    @Test func unreachableEnabledRegistrationStillSelfHeals() async throws {
        let harness = try HelperHarness()
        defer { harness.cleanUp() }
        harness.reachable = false
        let manager = harness.makeManager()
        manager.reconcileAfterUpdate()
        #expect(await harness.registered.waitAsync(for: .seconds(10)) == .success)
        #expect(harness.events == ["unregister", "register"])
        #expect(manager.isEnabled)
    }
}

final class HelperTestProxy: NSObject, Glimmer.GlimmerHelperProtocol, Sendable {
    let stalledEntered = DispatchSemaphore(value: 0)
    private let pendingDown = Mutex<(@Sendable (Bool) -> Void)?>(nil)
    private let suspendDown: Bool
    private let suspendCount: Bool

    init(suspendDown: Bool = false, suspendCount: Bool = false) {
        self.suspendDown = suspendDown
        self.suspendCount = suspendCount
    }

    func finishDown() { pendingDown.withLock { let reply = $0; $0 = nil; return reply }?(true) }

    func setAWDLDown(_ down: Bool, reason: String, reply: @escaping @Sendable (Bool) -> Void) {
        if down && suspendDown {
            pendingDown.withLock { $0 = reply }
            stalledEntered.signal()
        } else {
            reply(true)
        }
    }
    func currentStatus(reply: @escaping (Bool, Date?) -> Void) { reply(false, nil) }
    func ping(reply: @escaping (String) -> Void) { reply("test") }
    func reSuppressCount(reply: @escaping (UInt64) -> Void) {
        if suspendCount { stalledEntered.signal() } else { reply(0) }
    }
}
