// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
import Darwin

/// Requests borrow their caller's stack until completion; the condition protects the FIFO and lifecycle.
final class InputSendThread: @unchecked Sendable {
    private struct Request {
        let run: () -> Int32
        var result: Int32 = 0
        var next: UnsafeMutablePointer<Request>?
        var complete = false
    }

    private let condition = NSCondition()
    private var first: UnsafeMutablePointer<Request>?
    private var last: UnsafeMutablePointer<Request>?
    private var stopping = false
    private var finished = false
    private var deadline: DispatchTime?
    private var timer: (@Sendable () -> Void)?
    private var thread: Thread?

    init(realtime: Bool = true, configureThread: @escaping @Sendable () -> Void = {}) {
        let thread = Thread { [self] in
            if realtime { configureThread() }
            run()
        }
        thread.name = "Glimmer.inputSend"
        thread.qualityOfService = .userInteractive
        self.thread = thread
        thread.start()
    }

    /// Synchronous local acceptance keeps failed releases in the caller's obligation ledger.
    /// The borrowed request and closure cannot outlive this call, including during shutdown.
    @discardableResult
    func sync(_ body: () -> Int32) -> Int32 {
        if Thread.current === thread { return body() }
        return withoutActuallyEscaping(body) { operation in
            var request = Request(run: operation)
            return withUnsafeMutablePointer(to: &request) { pointer in
                condition.lock()
                precondition(!stopping)
                if let last { last.pointee.next = pointer } else { first = pointer }
                last = pointer
                condition.broadcast()
                while !pointer.pointee.complete { condition.wait() }
                let result = pointer.pointee.result
                condition.unlock()
                return result
            }
        }
    }

    func schedule(deadline: DispatchTime, action: @escaping @Sendable () -> Void) {
        condition.lock()
        self.deadline = deadline
        timer = action
        if Thread.current !== thread { condition.broadcast() }
        condition.unlock()
    }

    func cancelTimer() {
        condition.lock()
        deadline = nil
        timer = nil
        condition.unlock()
    }

    func stop() {
        condition.lock()
        stopping = true
        deadline = nil
        timer = nil
        condition.broadcast()
        while !finished && Thread.current !== thread { condition.wait() }
        condition.unlock()
    }

    private func run() {
        condition.lock()
        while !stopping || first != nil {
            if fireDueTimer() { continue }
            if let request = first {
                first = request.pointee.next
                if first == nil { last = nil }
                condition.unlock()
                let result = autoreleasepool { request.pointee.run() }
                condition.lock()
                request.pointee.result = result
                request.pointee.complete = true
                condition.broadcast()
            } else if let deadline {
                let now = DispatchTime.now()
                if now >= deadline {
                    let action = timer
                    self.deadline = nil
                    timer = nil
                    condition.unlock()
                    autoreleasepool { action?() }
                    condition.lock()
                } else {
                    let seconds = Double(deadline.uptimeNanoseconds - now.uptimeNanoseconds) / 1_000_000_000
                    _ = condition.wait(until: Date(timeIntervalSinceNow: seconds))
                }
            } else {
                condition.wait()
            }
        }
        finished = true
        condition.broadcast()
        condition.unlock()
    }

    /// Producers cannot starve a due merge deadline by keeping the request FIFO nonempty.
    private func fireDueTimer() -> Bool {
        guard let deadline, DispatchTime.now() >= deadline else { return false }
        let action = timer
        self.deadline = nil
        timer = nil
        condition.unlock()
        autoreleasepool { action?() }
        condition.lock()
        return true
    }
}
