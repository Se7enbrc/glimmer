// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import os
import Testing
@testable import Glimmer

extension DispatchSemaphore {
    // A zero-time probe consumes a signal without parking a cooperative worker.
    func takeSignal() -> DispatchTimeoutResult { wait(timeout: .now()) }

    func waitAsync(for duration: Duration) async -> DispatchTimeoutResult {
        let deadline = ContinuousClock.now + duration
        repeat {
            if takeSignal() == .success { return .success }
            do { try await Task.sleep(for: .milliseconds(1)) } catch { return .timedOut }
        } while ContinuousClock.now < deadline
        return takeSignal()
    }
}

// Socket calls and deliberately blocked callbacks need a real thread, not a Task.
func onTestThread<Value: Sendable>(_ operation: @escaping @Sendable () throws -> Value) async throws -> Value {
    try await withCheckedThrowingContinuation { continuation in
        Thread {
            continuation.resume(with: Result { try operation() })
        }.start()
    }
}

// Start synchronously so a fixture deadline never races a queued launch Task.
func startTestThread(_ operation: @escaping @Sendable () throws -> Void) -> AsyncThrowingStream<Void, Error> {
    AsyncThrowingStream { continuation in
        Thread {
            do {
                try operation()
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }.start()
    }
}

// Timing fixtures must resume independently of the suite's cooperative worker pool.
final class TestTaskExecutor: TaskExecutor {
    func enqueue(_ job: consuming ExecutorJob) {
        let unownedJob = UnownedJob(job)
        let executor = asUnownedTaskExecutor()
        Thread { unownedJob.runSynchronously(on: executor) }.start()
    }
}

extension DispatchQueue {
    func drainForTest() async {
        await withCheckedContinuation { continuation in
            async { continuation.resume() }
        }
    }
}

// The peer handles the whole exchange on its own thread, including the reply.
func withControlPeer(
    host: String, port: LoopbackPort, handle: @escaping @Sendable (Int32) throws -> Void
) async throws -> ControlTransport.Response {
    let started = DispatchSemaphore(value: 0)
    let finished = ManagedAtomicFlag()
    let listener = port.fd
    let peerResult = AsyncThrowingStream<Void, Error> { continuation in
        Thread {
            started.wait()
            do {
                let peer = try acceptControlPeer(on: listener, requestFinished: finished)
                defer { close(peer) }
                try handle(peer)
                continuation.finish()
            } catch {
                continuation.finish(throwing: error)
            }
        }.start()
    }
    let response: Result<ControlTransport.Response, Error>
    started.signal()
    do {
        response = .success(try await ControlTransport.get(
            host: host, port: Int(port.port), target: "/serverinfo", userAgent: "GlimmerTests", tls: false,
            credential: .init(clientCertPEM: nil, clientKeyPEM: nil, pinnedCertPEM: nil), timeout: 5))
    } catch {
        response = .failure(error)
    }
    finished.set()
    for try await _ in peerResult {}
    return try response.get()
}

// Only cancellation-to-EOF is a latency assertion; the generous setup limit
// just keeps a request that stalls before sending from hanging the suite.
func acceptControlConnection(on listener: Int32, requestFinished: ManagedAtomicFlag) async throws -> Int32 {
    try await onTestThread {
        try acceptControlPeer(on: listener, requestFinished: requestFinished)
    }
}

private func acceptControlPeer(on listener: Int32, requestFinished: ManagedAtomicFlag) throws -> Int32 {
    let deadline = ContinuousClock.now + .seconds(10)
    let flags = fcntl(listener, F_GETFL, 0)
    guard flags >= 0, fcntl(listener, F_SETFL, flags | O_NONBLOCK) == 0 else {
        throw TestSocketError.setupFailed
    }
    try waitForControlReadability(listener, requestFinished: requestFinished, until: deadline)
    let peer = accept(listener, nil, nil)
    guard peer >= 0 else { throw TestSocketError.setupFailed }
    // Seeing request bytes proves cancellation interrupts a read, not just connection setup.
    do {
        try waitForControlReadability(peer, requestFinished: requestFinished, until: deadline)
    } catch {
        close(peer)
        throw error
    }
    return peer
}

func waitForControlReadability(
    _ fd: Int32, requestFinished: ManagedAtomicFlag, until deadline: ContinuousClock.Instant
) throws {
    while !requestFinished.isSet {
        let remaining = ContinuousClock.now.duration(to: deadline) / .milliseconds(1)
        let milliseconds = Int32(max(0, min(100, remaining.rounded(.up))))
        var pending = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        let ready = poll(&pending, 1, milliseconds)
        if ready < 0, errno == EINTR { continue }
        guard ready >= 0 else { throw TestSocketError.setupFailed }
        if ready > 0, pending.revents & Int16(POLLIN) != 0 { return }
        guard pending.revents & Int16(POLLERR | POLLHUP | POLLNVAL) == 0 else {
            throw TestSocketError.setupFailed
        }
        guard ContinuousClock.now < deadline else { throw TestSocketError.setupTimedOut }
    }
    throw TestSocketError.requestEndedBeforeCancellation
}

/// Drain pending request bytes to observe the peer closing before the deadline.
func controlPeerReachesEOF(_ fd: Int32, before deadline: ContinuousClock.Instant) -> Bool {
    let flags = fcntl(fd, F_GETFL, 0)
    guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else { return false }
    var buffer = [UInt8](repeating: 0, count: 4096)
    while ContinuousClock.now < deadline {
        let milliseconds = Int32((ContinuousClock.now.duration(to: deadline) / .milliseconds(1)).rounded(.up))
        guard milliseconds > 0 else { return false }
        var pending = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&pending, 1, milliseconds) > 0 else { return false }
        let count = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        if count == 0 { return ContinuousClock.now <= deadline }
        if count < 0 { return false }
    }
    return false
}

enum TestSocketError: Error {
    case setupFailed, setupTimedOut, requestEndedBeforeCancellation
}

// A thread the kernel parks right after it signals is blocked on the lock the test is holding.
func threadParks(_ thread: thread_act_t, within duration: Duration) async -> Bool {
    let deadline = ContinuousClock.now + duration
    while true {
        var info = thread_basic_info()
        var count = mach_msg_type_number_t(MemoryLayout<thread_basic_info>.size / MemoryLayout<integer_t>.size)
        let status = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                thread_info(thread, thread_flavor_t(THREAD_BASIC_INFO), $0, &count)
            }
        }
        if status == KERN_SUCCESS, info.run_state == TH_STATE_WAITING { return true }
        // Check again after a late wake before giving up.
        if ContinuousClock.now >= deadline { return false }
        try? await Task.sleep(for: .milliseconds(1))
    }
}

// Manual deadlines still execute on the sender, preserving its merge-state isolation.
final class InputBatcherScheduler: Sendable {
    let clock = ScriptedClock()
    private struct Pending: Sendable {
        let deadline: DispatchTime
        let sender: InputSendThread
        let action: @Sendable () -> Void
    }
    private let pending = OSAllocatedUnfairLock<Pending?>(initialState: nil)

    var deadline: DispatchTime? { pending.withLock { $0?.deadline } }

    func makeBatcher(enet: EnetControlChannel,
                     tracker: @escaping @Sendable () -> FrameTimingTracker? = { nil },
                     backpressure: @escaping @Sendable (EnetControlChannel) -> Bool = {
                         $0.sendBacklogged || $0.reliableBacklogged
                     }) -> InputBatcher {
        InputBatcher(enet: enet, now: { [clock] in DispatchTime(uptimeNanoseconds: clock.nanos) },
                     tracker: tracker, backpressure: backpressure, scheduleFlush: { [self] sender, time, action in
            pending.withLock { $0 = Pending(deadline: time, sender: sender, action: action) }
        })
    }

    func fire() throws {
        let next = pending.withLock { value in
            defer { value = nil }
            return value
        }
        let tick = try #require(next)
        #expect(tick.deadline.uptimeNanoseconds >= clock.nanos)
        clock.advance(.nanoseconds(Int64(tick.deadline.uptimeNanoseconds - clock.nanos)))
        tick.sender.sync { tick.action(); return 0 }
    }
}

// A request handshake proves the task reached its delay before the test resumes it.
@MainActor
final class TestDelay {
    let requests = AsyncStream<Duration>.makeStream()
    private var continuation: CheckedContinuation<Void, Never>?

    func sleep(_ duration: Duration) async throws {
        await withCheckedContinuation {
            continuation = $0
            requests.continuation.yield(duration)
        }
        try Task.checkCancellation()
    }

    func resume() {
        continuation?.resume()
        continuation = nil
    }
}
