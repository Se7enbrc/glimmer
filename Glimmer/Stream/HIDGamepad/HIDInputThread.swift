// SPDX-License-Identifier: GPL-3.0-only
// SPDX-FileCopyrightText: 2026 ugfugl.io

import Foundation

/// The condition publishes the run loop once; all HID scheduling and report drains execute on that loop.
final class HIDInputThread: @unchecked Sendable {
    static let shared = HIDInputThread()
    private let condition = NSCondition()
    private var loop: CFRunLoop?

    private init() {
        let thread = Thread { [self] in
            let loop = CFRunLoopGetCurrent()
            var context = CFRunLoopSourceContext()
            let source = CFRunLoopSourceCreate(nil, 0, &context)
            CFRunLoopAddSource(loop, source, .commonModes)
            condition.lock()
            self.loop = loop
            condition.broadcast()
            condition.unlock()
            CFRunLoopRun()
        }
        thread.name = "Glimmer.hidCapture"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    func perform(_ body: @escaping @Sendable () -> Void) {
        condition.lock()
        while loop == nil { condition.wait() }
        let loop = self.loop
        condition.unlock()
        CFRunLoopPerformBlock(loop, CFRunLoopMode.commonModes.rawValue, body)
        CFRunLoopWakeUp(loop)
    }

    func sync(_ body: @escaping @Sendable () -> Void) {
        let done = DispatchSemaphore(value: 0)
        perform { body(); done.signal() }
        done.wait()
    }

    private static let secondsPerTick: Double = {
        var timebase = mach_timebase_info_data_t()
        mach_timebase_info(&timebase)
        return Double(timebase.numer) / Double(timebase.denom) / 1e9
    }()

    static func seconds(ticks: UInt64) -> TimeInterval { Double(ticks) * secondsPerTick }
}
