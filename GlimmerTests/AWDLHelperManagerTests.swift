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
    var releaseGate: HelperGate?
    var downGate: HelperGate?
    var countGate: HelperGate?
    var registrationGate: HelperGate?
    var retryGate: HelperGate?
    var recoveryGate: HelperGate?
    var retryDelays: [Duration] = []
    var persistentReleaseFailure = false
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
                    await self.downGate?.wait()
                    return true
                }
                await self.releaseGate?.wait()
                let result = self.persistentReleaseFailure ? false : self.releaseResults.removeFirst()
                self.events.append(result ? "restored" : "release-failed")
                self.released.signal()
                return result
            },
            invalidate: { self.events.append("invalidate") },
            reachable: { self.reachable },
            count: {
                await self.countGate?.wait()
                return 1
            },
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
    func permanentReleaseFailureCompletesTeardown(queueEnable: Bool) async throws {
        let harness = try HelperHarness()
        defer { harness.cleanUp() }
        let manager = harness.makeManager()
        manager.suppressForStream()
        #expect(await harness.tick.waitAsync(for: .seconds(10)) == .success)
        harness.persistentReleaseFailure = true
        let recovery = HelperGate()
        harness.recoveryGate = recovery
        manager.disable()
        #expect(await recovery.entered.waitAsync(for: .seconds(10)) == .success)
        if queueEnable { manager.enable() }
        for _ in 0..<3 {
            #expect(!harness.events.contains("unregister"))
            #expect(!harness.events.contains("register"))
            recovery.open()
            #expect(await recovery.entered.waitAsync(for: .seconds(10)) == .success)
        }
        #expect(harness.events.last == "invalidate")
        recovery.open()
        let completed = await harness.unregistered.waitAsync(for: .seconds(10)) == .success
        #expect(completed)
        #expect(harness.events.filter { $0 == "release-failed" }.count == 7)
        #expect(harness.retryDelays == [1, 2, 4, 10, 10, 10, 10].map { .seconds($0) })
        // Let an unbounded implementation finish too, so a regression leaves no task behind.
        if !completed {
            harness.persistentReleaseFailure = false
            recovery.open()
            #expect(await harness.unregistered.waitAsync(for: .seconds(10)) == .success)
        }
        if queueEnable {
            #expect(await harness.registered.waitAsync(for: .seconds(10)) == .success)
            #expect(manager.isEnabled)
            #expect(harness.events.suffix(3) == ["unregister", "unregister", "register"])
            manager.disable()
        } else {
            #expect(manager.state == .notRegistered)
            #expect(!manager.isEnabled)
            manager.enable()
            #expect(await harness.registered.waitAsync(for: .seconds(10)) == .success)
            #expect(manager.isEnabled)
            manager.disable()
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

private final class HelperTestProxy: NSObject, Glimmer.GlimmerHelperProtocol {
    func setAWDLDown(_ down: Bool, reason: String, reply: @escaping @Sendable (Bool) -> Void) { reply(true) }
    func currentStatus(reply: @escaping (Bool, Date?) -> Void) { reply(false, nil) }
    func ping(reply: @escaping (String) -> Void) { reply("test") }
    func reSuppressCount(reply: @escaping (UInt64) -> Void) { reply(0) }
}

struct HelperClientTests {
    @Test func errorsRetainConnectionAndStaleInvalidationsCannotDropReplacement() async throws {
        let identities = Mutex<[ObjectIdentifier]>([])
        let fail = Mutex(false)
        let invalidated = DispatchSemaphore(value: 0)
        let listener = NSXPCListener.anonymous()
        defer { listener.invalidate() }
        let endpoint = listener.endpoint
        let client = HelperClient(makeConnection: {
            let connection = NSXPCConnection(listenerEndpoint: endpoint)
            #expect(connection.serviceName == nil)
            #expect(connection.endpoint === endpoint)
            identities.withLock { $0.append(ObjectIdentifier(connection)) }
            return connection
        }, makeProxy: { connection, error in
            #expect(connection.interruptionHandler == nil)
            let original = connection.invalidationHandler
            connection.invalidationHandler = {
                invalidated.signal()
                original?()
            }
            if fail.withLock({ $0 }) {
                error(CancellationError())
                // A late reply after a transport failure must not resume twice.
            }
            return HelperTestProxy()
        })
        #expect(await client.setAWDLDown(true, reason: "test"))
        let first = try #require(identities.withLock { $0.first })
        fail.withLock { $0 = true }
        #expect(!(await client.setAWDLDown(false, reason: "test")))
        #expect(await client.currentStatus() == nil)
        #expect(await client.reSuppressCount() == nil)
        #expect(identities.withLock { $0.count } == 1)
        await client.drop(first)
        #expect(await invalidated.waitAsync(for: .seconds(10)) == .success)
        fail.withLock { $0 = false }
        #expect(await client.reSuppressCount() == 0)
        #expect(identities.withLock { $0.count } == 2)
        await client.drop(first)
        #expect(await client.reSuppressCount() == 0)
        #expect(identities.withLock { $0.count } == 2)
        await client.invalidate()
    }
}
