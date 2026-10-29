// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import Synchronization
#if canImport(GlimmerEngine)
@testable import GlimmerEngine
#endif
@testable import Glimmer

extension CleanRoomProbe {
    // Ops are "call:mode": call is status, down or count; mode is reply, silent (never answers)
    // or late (answers when the next op starts). Each op records the result and connection churn.
    struct HelperInput: Codable, Sendable {
        let ops: [String]
    }

    struct HelperOutput: Codable, Equatable, Sendable {
        let events: [String]
    }

    static let helper = area("helper") { (input: HelperInput) -> HelperOutput in await observeHelper(input) }

    // Scripted helper on a test-owned anonymous listener; the lock guards the mode and parked replies.
    private final class ScriptedHelper: NSObject, GlimmerHelperProtocol, NSXPCListenerDelegate, @unchecked Sendable {
        let listener = NSXPCListener.anonymous()
        let state = Mutex((mode: "reply", parked: [@Sendable () -> Void](), accepted: [Lease]()))

        func listener(_ listener: NSXPCListener, shouldAcceptNewConnection connection: NSXPCConnection) -> Bool {
            connection.exportedInterface = NSXPCInterface(with: GlimmerHelperProtocol.self)
            connection.exportedObject = self
            state.withLock { $0.accepted.append(Lease(connection: connection)) }
            connection.resume()
            return true
        }

        private func answer(_ reply: @escaping @Sendable () -> Void) {
            let mode = state.withLock { state in
                if state.mode != "reply" { state.parked.append(reply) }
                return state.mode
            }
            if mode == "reply" { reply() }
        }

        func releaseLate() -> Int {
            let parked = state.withLock { state in
                let parked = state.mode == "late" ? state.parked : []
                state.parked = state.mode == "late" ? [] : state.parked
                return parked
            }
            parked.forEach { $0() }
            return parked.count
        }

        func setAWDLDown(_ down: Bool, reason: String, reply: @escaping @Sendable (Bool) -> Void) {
            answer { reply(true) }
        }
        // XPC reply blocks are thread-safe to call once from any queue.
        func currentStatus(reply: @escaping (Bool, Date?) -> Void) {
            nonisolated(unsafe) let reply = reply
            answer { reply(true, nil) }
        }
        func ping(reply: @escaping (String) -> Void) { reply("ping") }
        func reSuppressCount(reply: @escaping (UInt64) -> Void) {
            // Same XPC reply-block guarantee as currentStatus.
            nonisolated(unsafe) let reply = reply
            answer { reply(7) }
        }
    }

    // NSXPCConnection is thread-safe; the probe only counts transports and pings earlier ones.
    private struct Lease: @unchecked Sendable {
        let connection: NSXPCConnection
    }

    @MainActor
    static func observeHelper(_ input: HelperInput) async -> HelperOutput {
        let service = ScriptedHelper()
        service.listener.delegate = service
        service.listener.resume()
        let made = Mutex([Lease]())
        let client = HelperClient(makeConnection: {
            let connection = NSXPCConnection(listenerEndpoint: service.listener.endpoint)
            made.withLock { $0.append(Lease(connection: connection)) }
            return connection
        })
        var events: [String] = []
        for op in input.ops {
            let parts = op.split(separator: ":").map(String.init)
            let released = service.releaseLate()
            service.state.withLock { $0.mode = parts.count > 1 ? parts[1] : "reply" }
            let result: String = switch parts[0] {
            case "down": "\(await client.setAWDLDown(true, reason: "differential"))"
            case "count": "\(await client.reSuppressCount().map(String.init) ?? "nil")"
            default: "\(await client.currentStatus().map { "\($0.0)" } ?? "nil")"
            }
            let connections = made.withLock { $0 }
            var line = "\(op) -> \(result) connections \(connections.count) late \(released)"
            if connections.count > 1 { line += " previous " + (await ping(connections[connections.count - 2])) }
            events.append(line)
        }
        await client.invalidate()
        service.listener.invalidate()
        service.state.withLock { $0.accepted }.forEach { $0.connection.invalidate() }
        return HelperOutput(events: events)
    }

    // Whether an earlier client transport still delivers messages after the client replaced it.
    private static func ping(_ lease: Lease) async -> String {
        let connection = lease.connection
        return await withCheckedContinuation { (continuation: CheckedContinuation<String, Never>) in
            let once = SingleResume(continuation)
            let deadline = Task {
                try? await Task.sleep(for: .seconds(1))
                _ = once.resume("expired")
            }
            let proxy = connection.remoteObjectProxyWithErrorHandler { _ in
                _ = once.resume("rejected")
            } as? GlimmerHelperProtocol
            guard let proxy else { _ = once.resume("rejected"); return }
            proxy.ping { _ in if once.resume("answered") { deadline.cancel() } }
        }
    }
}
