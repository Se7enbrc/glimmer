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
                let result = self.releaseResults.removeFirst()
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
        let client = HelperClient(makeConnection: {
            let connection = NSXPCConnection(machServiceName: glimmerHelperMachServiceName, options: .privileged)
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
