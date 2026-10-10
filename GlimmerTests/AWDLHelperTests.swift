// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import Darwin
import Synchronization
import Testing
@testable import Glimmer

struct AWDLHelperTests {
    @Test func oldPeerCannotReleaseItsReplacement() async {
        let up = Mutex(false)
        let suppressor = AWDLSuppressor(interfaceIsUp: { up.withLock { $0 } }, runIfconfig: { _ in
            up.withLock { $0 = true }
            return true
        })
        let service = HelperService(suppressor: suppressor)
        let first = UUID()
        let replacement = UUID()
        service.setAWDLDown(true, reason: "first", peer: first) { _ in }
        service.setAWDLDown(true, reason: "replacement", peer: replacement) { _ in }
        service.peerInvalidated(first)
        service.peerInvalidated(UUID())
        await withCheckedContinuation { continuation in
            suppressor.afterPendingChanges { continuation.resume() }
        }
        #expect(suppressor.suppressing)
        #expect(!up.withLock { $0 })
        service.peerInvalidated(replacement)
        await withCheckedContinuation { continuation in
            suppressor.afterPendingChanges { continuation.resume() }
        }
        #expect(!suppressor.suppressing)
        #expect(up.withLock { $0 })
    }

    @Test func replacementPeerCanExplicitlyReleaseTheOldLease() async {
        let up = Mutex(false)
        let suppressor = AWDLSuppressor(interfaceIsUp: { up.withLock { $0 } }, runIfconfig: { _ in
            up.withLock { $0 = true }
            return true
        })
        let service = HelperService(suppressor: suppressor)
        service.setAWDLDown(true, reason: "first", peer: UUID()) { _ in }
        let released = await withCheckedContinuation { continuation in
            service.setAWDLDown(false, reason: "replacement", peer: UUID()) { continuation.resume(returning: $0) }
        }
        #expect(released)
        #expect(!suppressor.suppressing)
        #expect(up.withLock { $0 })
    }

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
        let interfaceUp = Mutex(false)
        let suppressor = AWDLSuppressor(
            interfaceIsUp: { interfaceUp.withLock { $0 } },
            runIfconfig: { args in
                restoreStarted.signal()
                allowRestore.wait()
                operations.withLock { $0.append(args.last ?? "") }
                interfaceUp.withLock { $0 = true }
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

    @Test(arguments: [false, true])
    func failedRestorationRetriesBeforeIdleExit(commandSucceeded: Bool) async {
        let start = ContinuousClock.now
        let clock = Mutex(start)
        let interfaceUp = Mutex(false)
        let recover = Mutex(false)
        let attempts = Mutex(0)
        let suppressor = AWDLSuppressor(interfaceIsUp: { interfaceUp.withLock { $0 } }, runIfconfig: { _ in
            attempts.withLock { $0 += 1 }
            if recover.withLock({ $0 }) { interfaceUp.withLock { $0 = true } }
            return commandSucceeded
        }, clockNow: { clock.withLock { $0 } })
        let service = HelperService(suppressor: suppressor)
        let released = await withCheckedContinuation { continuation in
            service.setAWDLDown(false, reason: "test") { continuation.resume(returning: $0) }
        }
        #expect(!released)
        #expect(attempts.withLock { $0 } == 1)
        clock.withLock { $0 = start + .seconds(10) }
        #expect(suppressor.withHeartbeatDecision(at: start + .seconds(10)) { $0 } == .restoring)
        recover.withLock { $0 = true }
        suppressor.poll()
        await withCheckedContinuation { continuation in
            suppressor.afterPendingChanges { continuation.resume() }
        }
        #expect(attempts.withLock { $0 } == 2)
        #expect(interfaceUp.withLock { $0 })
        #expect(suppressor.withHeartbeatDecision(at: start + .seconds(10)) { $0 } == .exit(.seconds(10)))
    }

    @Test func onlyExplicitMissingLaunchdJobPermitsRepair() {
        let missing = "Could not find service \"io.ugfugl.glimmer.helper\" in domain for system"
        #expect(AWDLHelperRecovery.confirmsMissingJob(status: 113, error: missing))
        #expect(!AWDLHelperRecovery.confirmsMissingJob(status: nil, error: missing))
        #expect(!AWDLHelperRecovery.confirmsMissingJob(status: 0, error: missing))
        #expect(!AWDLHelperRecovery.confirmsMissingJob(status: 113, error: "Operation not permitted"))
        #expect(!AWDLHelperRecovery.confirmsMissingJob(status: 113,
                                                     error: "Could not find service \"other\" in domain for system"))
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
        #expect(suppressor.withHeartbeatDecision(at: start + .seconds(9)) { $0 } == .restoring)
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

struct AWDLProcessTests {
    @Test func capturesOutputAndRejectsNonzeroExit() throws {
        let success = try #require(AWDLProcess.run(arguments: ["-c", "printf ready"], executable: "/bin/sh"))
        #expect(success.succeeded)
        #expect(String(data: success.output, encoding: .utf8) == "ready")
        let failure = try #require(AWDLProcess.run(arguments: ["-c", "exit 7"], executable: "/bin/sh"))
        #expect(!failure.succeeded)
        #expect(failure.status == 7 << 8)
        let stderr = try #require(AWDLProcess.run(arguments: ["-c", "printf failure >&2; exit 7"],
                                                 executable: "/bin/sh", captureErrors: true))
        #expect(String(data: stderr.output, encoding: .utf8) == "failure")
        #expect(AWDLProcess.run(arguments: [], executable: "/nonexistent/glimmer-test") == nil)
    }

    @Test func capsOutputAndDrainsBeyondTheCap() throws {
        let result = try #require(AWDLProcess.run(arguments: ["-c", "printf 123456"], executable: "/bin/sh", outputLimit: 3))
        #expect(result.truncated)
        #expect(!result.succeeded)
        #expect(String(data: result.output, encoding: .utf8) == "123")
        let streaming = try #require(AWDLProcess.run(arguments: [], executable: "/usr/bin/yes",
                                                    timeout: .milliseconds(100), grace: .milliseconds(100), outputLimit: 3))
        #expect(streaming.timedOut)
        #expect(streaming.truncated)
        #expect(streaming.output.count == 3)
    }

    @Test(arguments: [false, true])
    func timeoutReapsTheChildBeforeReturning(ignoreTerm: Bool) throws {
        let command = ignoreTerm ? "trap '' TERM; printf '%s' $$; exec /bin/sleep 30" : "printf '%s' $$; exec /bin/sleep 30"
        let start = ContinuousClock.now
        let result = try #require(AWDLProcess.run(arguments: ["-c", command], executable: "/bin/sh",
                                                timeout: .milliseconds(500), grace: .milliseconds(100)))
        #expect(result.timedOut)
        #expect(!result.succeeded)
        #expect(result.status & 0x7f == (ignoreTerm ? SIGKILL : SIGTERM))
        #expect(start.duration(to: .now) < .seconds(5))
        let pidText = try #require(String(data: result.output, encoding: .utf8))
        let child = try #require(Int32(pidText))
        var status: Int32 = 0
        #expect(waitpid(child, &status, WNOHANG) == -1)
        #expect(errno == ECHILD)
    }
}

@MainActor
struct AWDLLayoutMigrationTests {
    @Test(arguments: [false, true], [false, true])
    func disableWaitsForInitialProbeAndRestoration(cancelBeforeProbe: Bool, currentLayout: Bool) async throws {
        let harness = try HelperHarness()
        defer { harness.cleanUp() }
        harness.layout = currentLayout ? .current : .legacyActive
        let probe = HelperGate()
        let release = HelperGate()
        harness.layoutGate = probe
        harness.releaseGate = release
        let manager = harness.makeManager()
        manager.reconcileAfterUpdate()
        if cancelBeforeProbe { manager.disable() }
        #expect(await probe.entered.waitAsync(for: .seconds(5)) == .success)
        if !cancelBeforeProbe { manager.disable() }
        #expect(harness.events.isEmpty)
        probe.open()
        #expect(await release.entered.waitAsync(for: .seconds(5)) == .success)
        #expect(harness.events == ["helper-update"])
        release.open()
        #expect(await harness.unregistered.waitAsync(for: .seconds(5)) == .success)
        #expect(harness.events == ["helper-update", "restored", "invalidate", "unregister"])
    }

    @Test(arguments: [false, true])
    func reconciliationMigratesActiveAndIdleLegacyJobs(idle: Bool) async throws {
        let harness = try HelperHarness()
        defer { harness.cleanUp() }
        harness.layout = idle ? .legacyIdle : .legacyActive
        let manager = harness.makeManager()
        manager.reconcileAfterUpdate()
        #expect(await harness.registered.waitAsync(for: .seconds(5)) == .success)
        #expect(harness.events == (idle ? ["unregister", "register"] : ["helper-update", "restored", "unregister", "register"]))
    }

    @Test func cancellationCannotBypassMigrationRestoration() async throws {
        let harness = try HelperHarness()
        defer { harness.cleanUp() }
        harness.layout = .legacyActive
        let gate = HelperGate()
        harness.releaseGate = gate
        let manager = harness.makeManager()
        manager.reconcileAfterUpdate()
        #expect(await gate.entered.waitAsync(for: .seconds(5)) == .success)
        manager.disable()
        #expect(harness.events == ["helper-update"])
        gate.open()
        #expect(await harness.unregistered.waitAsync(for: .seconds(5)) == .success)
        #expect(harness.events == ["helper-update", "restored", "invalidate", "unregister"])
    }

    @Test func unknownLayoutRetriesUntilReleaseIsSafe() async {
        var probes = 0
        var releases = 0
        var retries = 0
        let replace = await AWDLHelperRecovery.prepareMigration(layout: {
            probes += 1
            return probes == 1 ? .unknown : .legacyIdle
        }, release: { releases += 1; return false }, sleep: { _ in retries += 1 })
        #expect(replace && releases == 1 && retries == 1)
        let current = await AWDLHelperRecovery.prepareMigration(layout: { .current },
                                                                release: { releases += 1; return true }, sleep: { _ in })
        #expect(!current && releases == 1)
    }

    @Test func unconfirmableReleaseGivesUpAndReplaces() async {
        var releases = 0
        var sleeps = 0
        let replace = await AWDLHelperRecovery.prepareMigration(layout: { .unknown },
                                                                release: { releases += 1; return false },
                                                                sleep: { _ in sleeps += 1 }, maxReleases: 4)
        #expect(replace && releases == 4 && sleeps == 4)
    }

    @Test func onlyConfirmedCleanLegacyIdleStateSkipsRelease() {
        let clean = """
        system/io.ugfugl.glimmer.helper = {
        \tprogram identifier = Contents/MacOS/io.ugfugl.glimmer.helper (mode: 2)
        \tstate = not running
        \tactive count = 0
        \truns = 8
        \tlast exit code = 0
        }
        """
        #expect(AWDLHelperRecovery.layout(status: 0, output: clean) == .legacyIdle)
        for changed in [clean.replacingOccurrences(of: "last exit code = 0", with: "last exit code = 1"),
                        clean + "\n\tpid = 42", clean + "\n\tlast terminating signal = Killed: 9",
                        clean.replacingOccurrences(of: "active count = 0", with: "active count = 1")] {
            #expect(AWDLHelperRecovery.layout(status: 0, output: changed) == .legacyActive)
        }
        #expect(AWDLHelperRecovery.layout(status: 1, output: clean) == .unknown)
        #expect(AWDLHelperRecovery.layout(status: 0, output: "unrecognized") == .unknown)
        let neverRun = clean.replacingOccurrences(of: "runs = 8", with: "runs = 0")
            .replacingOccurrences(of: "\tlast exit code = 0\n", with: "")
        #expect(AWDLHelperRecovery.layout(status: 0, output: neverRun) == .legacyIdle)
    }
}

struct HelperClientTests {
    @Test(arguments: [false, true])
    func timedOutRequestsRetireLiveConnections(duringCount: Bool) async throws {
        let connections = Mutex<[HelperTestConnection]>([])
        let proxy = HelperTestProxy(suspendDown: !duringCount, suspendCount: duringCount)
        let delegate = HelperTestListener(proxy)
        let listener = NSXPCListener.anonymous()
        listener.delegate = delegate
        listener.resume()
        defer {
            listener.invalidate()
            withExtendedLifetime(delegate) {}
        }
        let endpoint = listener.endpoint
        let bootstrap = HelperTestConnection(value: NSXPCConnection(listenerEndpoint: endpoint))
        bootstrap.value.remoteObjectInterface = NSXPCInterface(with: Glimmer.GlimmerHelperProtocol.self)
        bootstrap.value.resume()
        defer { bootstrap.value.invalidate() }
        // Listener startup is not part of the request deadline this test exercises.
        try #require(await Self.ping(bootstrap) == .reply("test"))
        let client = HelperClient(makeConnection: {
            let connection = NSXPCConnection(listenerEndpoint: endpoint)
            let probe = HelperTestConnection(value: connection)
            connections.withLock { $0.append(probe) }
            return connection
        })
        for attempt in 1...3 {
            #expect(await client.currentStatus()?.0 == false)
            let connection = try #require(connections.withLock { $0.last })
            // No interruption handler: interrupted connections stay up for launchd's relaunch.
            #expect(connection.value.interruptionHandler == nil)
            #expect(await Self.ping(connection) == .reply("test"))
            if duringCount {
                #expect(await client.reSuppressCount() == nil)
            } else {
                #expect(!(await client.setAWDLDown(true, reason: "test")))
            }
            #expect(await Self.ping(connection)
                == .error(NSCocoaErrorDomain, CocoaError.Code.xpcConnectionInvalid.rawValue))
            #expect(connections.withLock { $0.count } == attempt)
            proxy.finishDown()
        }
        #expect(await client.currentStatus()?.0 == false)
        #expect(connections.withLock { $0.count } == 4)
        await client.invalidate()
    }

    private enum Ping: Equatable, Sendable {
        case reply(String)
        case error(String, Int)
        case noProxy
    }

    private static func ping(_ connection: HelperTestConnection) async -> Ping {
        await withCheckedContinuation { continuation in
            let once = SingleResume(continuation)
            let remote = connection.value.remoteObjectProxyWithErrorHandler { error in
                let cocoa = error as NSError
                once.resume(.error(cocoa.domain, cocoa.code))
            }
            guard let proxy = remote as? Glimmer.GlimmerHelperProtocol else {
                once.resume(.noProxy)
                return
            }
            proxy.ping { once.resume(.reply($0)) }
        }
    }

    @Test func errorsRetainConnectionAndStaleInvalidationsCannotDropReplacement() async throws {
        let made = Mutex(0)
        let fail = Mutex(false)
        let invalidated = DispatchSemaphore(value: 0)
        let listener = NSXPCListener.anonymous()
        defer { listener.invalidate() }
        let endpoint = listener.endpoint
        let client = HelperClient(makeConnection: {
            let connection = NSXPCConnection(listenerEndpoint: endpoint)
            made.withLock { $0 += 1 }
            return connection
        }, makeProxy: { connection, error in
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
        // The first connection's generation; a freed connection's address can be reused, its generation cannot.
        let first = 1
        fail.withLock { $0 = true }
        #expect(!(await client.setAWDLDown(false, reason: "test")))
        #expect(await client.currentStatus() == nil)
        #expect(await client.reSuppressCount() == nil)
        #expect(made.withLock { $0 } == 1)
        await client.drop(first)
        #expect(await invalidated.waitAsync(for: .seconds(10)) == .success)
        fail.withLock { $0 = false }
        #expect(await client.reSuppressCount() == 0)
        #expect(made.withLock { $0 } == 2)
        await client.drop(first)
        #expect(await client.reSuppressCount() == 0)
        #expect(made.withLock { $0 } == 2)
        await client.invalidate()
    }
}

// Configuration and invalidation never overlap a probe; Foundation owns message-queue synchronisation.
private struct HelperTestConnection: @unchecked Sendable {
    let value: NSXPCConnection
}

private final class HelperTestListener: NSObject, NSXPCListenerDelegate, Sendable {
    private let proxy: HelperTestProxy

    init(_ proxy: HelperTestProxy) {
        self.proxy = proxy
    }

    func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
        connection.exportedInterface = NSXPCInterface(with: Glimmer.GlimmerHelperProtocol.self)
        connection.exportedObject = proxy
        connection.resume()
        return true
    }
}
