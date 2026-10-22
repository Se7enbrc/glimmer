// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

@testable import GlimmerEngine
import Foundation
import Network
import os
import Testing

struct EnetSocketReadinessTests {
    @Test func waitingSocketExpiresAtTheOriginalHandshakeDeadline() async throws {
        let channel = try EnetFixture.channel()
        let socket = SocketReadinessHarness()
        let deadline = DispatchTime(uptimeNanoseconds: 13_000_000_000)
        socket.advance(to: 5_000_000_000)
        let readiness = Task { try await socket.wait(on: channel, deadline: deadline) }
        await socket.started.wait()
        #expect(socket.scheduledDeadline == deadline.uptimeNanoseconds)
        socket.advance(to: deadline.uptimeNanoseconds - 1)
        #expect(socket.cancellations.value == 0)
        socket.advance(to: deadline.uptimeNanoseconds)
        #expect(socket.cancellations.value == 1)
        // Also releases the unfixed readiness wait, so the regression fails without hanging.
        socket.deliver(.cancelled)
        do {
            try await readiness.value
            Issue.record("Waiting socket became ready")
        } catch {
            #expect(channel.enetCode(error) == -110)
        }
        socket.deliver(.ready)
        socket.deliver(.cancelled)
        socket.deliver(.failed(.posix(.ENETDOWN)))
        #expect(socket.receives.value == 0)
        #expect(socket.cancellations.value == 1)
        #expect(!channel.withState { channel.disconnected })
    }

    @Test(arguments: [false, true])
    func readinessCompletionCancelsTheDeadline(interrupted: Bool) async throws {
        let channel = try EnetFixture.channel()
        let socket = SocketReadinessHarness()
        let deadline = DispatchTime(uptimeNanoseconds: 13_000_000_000)
        let readiness = Task { try await socket.wait(on: channel, deadline: deadline) }
        await socket.started.wait()
        if interrupted {
            channel.interrupt()
            socket.deliver(.cancelled)
        } else {
            socket.deliver(.ready)
        }
        do {
            try await readiness.value
            #expect(!interrupted)
        } catch {
            #expect(interrupted && channel.enetCode(error) == -4)
        }
        #expect(socket.deadlineCancelled)
        socket.advance(to: deadline.uptimeNanoseconds)
        socket.deliver(.ready)
        #expect(socket.cancellations.value == 0)
        #expect(socket.receives.value == (interrupted ? 0 : 1))
    }
}

private final class SocketReadinessHarness: Sendable {
    private struct State: Sendable {
        var now: UInt64 = 0
        var handler: (@Sendable (NWConnection.State) -> Void)?
        var deadline: DispatchTime?
        var expire: (@Sendable () -> Void)?
        var cancelled = false
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    let started = SafetyTestGate()
    let cancellations = AtomicCounter()
    let receives = AtomicCounter()

    var scheduledDeadline: UInt64? { state.withLock { $0.deadline?.uptimeNanoseconds } }
    var deadlineCancelled: Bool { state.withLock { $0.cancelled } }

    func wait(on channel: EnetControlChannel, deadline: DispatchTime) async throws {
        try await channel.awaitSocketReady(deadline: deadline, start: { [self] handler in
            state.withLock { $0.handler = handler }
            handler(.waiting(.posix(.ENETDOWN)))
            Task { await started.open() }
        }, cancel: { [weak self] in
            self?.cancellations.increment()
        }, receive: { [weak self] in
            self?.receives.increment()
        }, schedule: { [self] deadline, expire in
            state.withLock {
                $0.deadline = deadline
                $0.expire = expire
            }
            return { [weak self] in self?.state.withLock { $0.cancelled = true } }
        })
    }

    func deliver(_ update: NWConnection.State) {
        state.withLock { $0.handler }?(update)
    }

    func advance(to now: UInt64) {
        let due = state.withLock { state -> (@Sendable () -> Void)? in
            state.now = now
            guard let deadline = state.deadline, state.now >= deadline.uptimeNanoseconds,
                  !state.cancelled else { return nil }
            defer { state.expire = nil }
            return state.expire
        }
        due?()
    }
}
