// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation
@testable import GlimmerEngine
import Testing
import os

struct FramePacerTickThreadTests {
    @Test func stopFromAnotherThreadExitsRunLoopAndIsIdempotent() throws {
        let callbackRan = DispatchSemaphore(value: 0)
        let loopExited = DispatchSemaphore(value: 0)
        let worker = PacerTickThread {
            let loop = CFRunLoopGetCurrent()
            let observer = CFRunLoopObserverCreateWithHandler(
                nil, CFRunLoopActivity.exit.rawValue, false, 0
            ) { _, _ in loopExited.signal() }
            CFRunLoopAddObserver(loop, observer, .commonModes)
            CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) { callbackRan.signal() }
        }
        defer { worker.stop() }
        try #require(worker.start())
        try #require(callbackRan.wait(timeout: .now() + 2) == .success)
        worker.stop()
        #expect(loopExited.wait(timeout: .now() + 2) == .success)
        worker.stop()
    }

    @Test func stopFromTickCallbackReturnsAndExitsRunLoop() throws {
        let owner = OSAllocatedUnfairLock<PacerTickThread?>(initialState: nil)
        let allowStop = DispatchSemaphore(value: 0)
        let stopReturned = DispatchSemaphore(value: 0)
        let loopExited = DispatchSemaphore(value: 0)
        let worker = PacerTickThread {
            let loop = CFRunLoopGetCurrent()
            let observer = CFRunLoopObserverCreateWithHandler(
                nil, CFRunLoopActivity.exit.rawValue, false, 0
            ) { _, _ in loopExited.signal() }
            CFRunLoopAddObserver(loop, observer, .commonModes)
            CFRunLoopPerformBlock(loop, CFRunLoopMode.defaultMode.rawValue) {
                guard allowStop.wait(timeout: .now() + 2) == .success else {
                    Issue.record("Test did not permit tick-thread shutdown")
                    CFRunLoopStop(CFRunLoopGetCurrent())
                    return
                }
                let pacer = owner.withLock { value in
                    defer { value = nil }
                    return value
                }
                pacer?.stop()
                stopReturned.signal()
            }
        }
        owner.withLock { $0 = worker }
        defer { worker.stop() }
        try #require(worker.start())
        allowStop.signal()
        #expect(stopReturned.wait(timeout: .now() + 2) == .success)
        #expect(loopExited.wait(timeout: .now() + 2) == .success)
    }
}
