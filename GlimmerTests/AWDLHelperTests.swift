import Foundation
import Synchronization
import Testing
@testable import Glimmer

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
            let remote = connection.value.remoteObjectProxyWithErrorHandler { error in
                let cocoa = error as NSError
                continuation.resume(returning: .error(cocoa.domain, cocoa.code))
            }
            guard let proxy = remote as? Glimmer.GlimmerHelperProtocol else {
                continuation.resume(returning: .noProxy)
                return
            }
            proxy.ping { continuation.resume(returning: .reply($0)) }
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
